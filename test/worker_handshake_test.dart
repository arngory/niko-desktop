import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:niko_desktop/daemon/af_unix_connector.dart';
import 'package:niko_desktop/daemon/worker_handshake.dart';
import 'package:niko_desktop/daemon/worker_process.dart';
import 'package:niko_desktop/gen/experimental/boxdd/desktop_service.pbgrpc.dart';
import 'package:protobuf/well_known_types/google/protobuf/empty.pb.dart';

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Minimal fake DesktopService for AF_UNIX connector end-to-end gRPC tests.
class _FakeDesktop extends DesktopServiceBase {
  int calls = 0;

  @override
  Future<DaemonInfo> getDaemonInfo(ServiceCall call, Empty request) async {
    calls++;
    return DaemonInfo(version: 'niko-af-unix-test');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw GrpcError.unimplemented();
}

/// Local Dart AF_UNIX relay server implementing the exact Go `worker_handshake.go` server side
/// and forwarding raw HTTP/2 bytes to a local TCP gRPC server.
class _TestAfUnixWorkerRelay {
  _TestAfUnixWorkerRelay({
    required this.socketPath,
    required this.secret,
    required this.windowPid,
    required this.workerPid,
    required this.upstreamPort,
    this.corruptServerMac = false,
    this.closeMidHandshake = false,
  });

  final String socketPath;
  final Uint8List secret;
  final int windowPid;
  final int workerPid;
  final int upstreamPort;
  final bool corruptServerMac;
  final bool closeMidHandshake;

  ServerSocket? _server;
  int handshakesCompleted = 0;
  int connectionsAccepted = 0;
  final Set<String> seenClientNonces = {};
  final List<Socket> _activeSockets = [];

  Future<void> start() async {
    final addr = InternetAddress(socketPath, type: InternetAddressType.unix);
    _server = await ServerSocket.bind(addr, 0);
    _server!.listen(_handleClient);
  }

  void _handleClient(Socket client) {
    connectionsAccepted++;
    _activeSockets.add(client);
    unawaited(_serve(client));
  }

  Future<void> _serve(Socket client) async {
    Socket? upstream;
    try {
      final helloSize = workerHandshakeMagic.length + workerNonceSize;
      final incoming = StreamController<List<int>>();
      final helloCompleter = Completer<Uint8List>();
      final clientMacCompleter = Completer<Uint8List>();
      helloCompleter.future.ignore();
      clientMacCompleter.future.ignore();

      var stage = 0; // 0 = reading hello, 1 = reading client MAC, 2 = relaying
      final buf = BytesBuilder(copy: false);

      final sub = client.listen(
        (chunk) {
          if (stage == 2) {
            if (!incoming.isClosed) incoming.add(chunk);
            return;
          }
          buf.add(chunk);
          if (stage == 0 && buf.length >= helloSize) {
            final all = buf.takeBytes();
            stage = 1;
            helloCompleter.complete(Uint8List.sublistView(all, 0, helloSize));
            if (all.length > helloSize) {
              buf.add(Uint8List.sublistView(all, helloSize));
            }
          }
          if (stage == 1 && buf.length >= workerMacSize) {
            final all = buf.takeBytes();
            stage = 2;
            clientMacCompleter.complete(Uint8List.sublistView(all, 0, workerMacSize));
            if (all.length > workerMacSize && !incoming.isClosed) {
              incoming.add(Uint8List.sublistView(all, workerMacSize));
            }
          }
        },
        onError: (Object err, StackTrace st) {
          if (!helloCompleter.isCompleted) helloCompleter.completeError(err, st);
          if (!clientMacCompleter.isCompleted) clientMacCompleter.completeError(err, st);
          if (!incoming.isClosed) incoming.addError(err, st);
        },
        onDone: () {
          if (!helloCompleter.isCompleted) {
            helloCompleter.completeError(const SocketException('eof before hello'));
          }
          if (!clientMacCompleter.isCompleted) {
            clientMacCompleter.completeError(const SocketException('eof before client mac'));
          }
          if (!incoming.isClosed) unawaited(incoming.close());
        },
      );

      final hello = await helloCompleter.future.timeout(const Duration(seconds: 3));
      final magic = Uint8List.sublistView(hello, 0, workerHandshakeMagic.length);
      if (!constantTimeEquals(magic, workerHandshakeMagic)) {
        client.destroy();
        await sub.cancel();
        return;
      }
      final clientNonce = Uint8List.sublistView(hello, workerHandshakeMagic.length, helloSize);
      seenClientNonces.add(_bytesToHex(clientNonce));

      if (closeMidHandshake) {
        client.add(Uint8List(10));
        await client.flush();
        client.destroy();
        await sub.cancel();
        return;
      }

      final serverNonce = generateWorkerKey();
      final serverMac = computeWorkerServerMac(
        key: secret,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        windowPid: windowPid,
        workerPid: workerPid,
      );
      if (corruptServerMac) {
        serverMac[0] ^= 0xff;
      }

      final reply = BytesBuilder(copy: false)
        ..add(serverNonce)
        ..add(serverMac);
      client.add(reply.takeBytes());
      await client.flush();

      final clientMac = await clientMacCompleter.future.timeout(const Duration(seconds: 3));
      final expectedClientMac = computeWorkerClientMac(
        key: secret,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        windowPid: windowPid,
        workerPid: workerPid,
      );
      if (!constantTimeEquals(clientMac, expectedClientMac)) {
        client.destroy();
        await sub.cancel();
        return;
      }
      handshakesCompleted++;

      upstream = await Socket.connect(InternetAddress.loopbackIPv4, upstreamPort);
      _activeSockets.add(upstream);
      final up = upstream;
      final p1 = incoming.stream.listen(up.add, onDone: () => up.close(), onError: (_) => up.destroy());
      final p2 = up.listen(client.add, onDone: () => client.close(), onError: (_) => client.destroy());
      await Future.any([p1.asFuture<void>(), p2.asFuture<void>()]).catchError((Object _) {});
      await p1.cancel();
      await p2.cancel();
      await sub.cancel();
    } catch (_) {
      client.destroy();
    } finally {
      upstream?.destroy();
    }
  }

  Future<void> close() async {
    for (final s in _activeSockets) {
      s.destroy();
    }
    _activeSockets.clear();
    await _server?.close();
    try {
      File(socketPath).deleteSync();
    } catch (_) {}
  }
}

class _FixedWorkerProcess extends WorkerProcess {
  _FixedWorkerProcess(this._endpoint) : super(daemonExecutablePath: '');
  final WorkerEndpoint _endpoint;
  int restartCalls = 0;
  int handshakeSucceededCalls = 0;

  @override
  Future<WorkerEndpoint> ensureReady() async => _endpoint;

  @override
  Future<void> restart() async {
    restartCalls++;
  }

  @override
  void markHandshakeSucceeded() {
    handshakeSucceededCalls++;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  test('HMAC vectors match sing-box/experimental/boxdd/testdata/worker_handshake_vectors.json', () {
    // Exact vectors independently generated by Python and verified by Go in boxdd.
    const vectors = [
      (
        key: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
        nc: '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f',
        ns: '404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f',
        winPid: 1234,
        workPid: 5678,
        serverMac: '66f3ee69ed8f875a4ee6f16c4a52d8cfe49eaa47f1419e2bef0892df7ec6ef28',
        clientMac: '041ad7eefcd51ee0492ad9f6327a7018ccd2943bde1aa482700c9936b835ebd4',
      ),
      (
        key: 'ffffffffffffffffffffffffffffffff00000000000000000000000000000000',
        nc: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ns: '5555555555555555555555555555555555555555555555555555555555555555',
        winPid: 0x7fffffff,
        workPid: 0x80000001,
        serverMac: 'b9216e2b60d264e95c1434381733a682202fbcb36e7071c4ca693c8e2f0d7868',
        clientMac: '248357f19795fc14984e911db9e1c61a2ee9ed6c39ec2d922487873f96654bd7',
      ),
    ];

    for (final v in vectors) {
      final key = _hexToBytes(v.key);
      final nc = _hexToBytes(v.nc);
      final ns = _hexToBytes(v.ns);
      final sMac = computeWorkerServerMac(
        key: key,
        clientNonce: nc,
        serverNonce: ns,
        windowPid: v.winPid,
        workerPid: v.workPid,
      );
      final cMac = computeWorkerClientMac(
        key: key,
        clientNonce: nc,
        serverNonce: ns,
        windowPid: v.winPid,
        workerPid: v.workPid,
      );
      expect(_bytesToHex(sMac), v.serverMac);
      expect(_bytesToHex(cMac), v.clientMac);
      expect(encodeWorkerKeyLine(key), '${v.key}\n');
    }

    expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
    expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
    expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
  });

  test('WorkerTransportConnector delivers gRPC calls and performs fresh handshake after idleTimeout', () async {
    final service = _FakeDesktop();
    final grpcServer = Server.create(services: [service]);
    await grpcServer.serve(address: InternetAddress.loopbackIPv4, port: 0);
    final dir = Directory.systemTemp.createTempSync('nk-conn-');
    final sockPath = '${dir.path}${Platform.pathSeparator}w.sock';
    final secret = generateWorkerKey();
    final relay = _TestAfUnixWorkerRelay(
      socketPath: sockPath,
      secret: secret,
      windowPid: 1111,
      workerPid: 2222,
      upstreamPort: grpcServer.port!,
    );
    await relay.start();

    final connector = WorkerTransportConnector(
      _FixedWorkerProcess(WorkerEndpoint(bindPath: sockPath, secret: secret, windowPid: 1111, workerPid: 2222)),
    );
    final channel = ClientTransportConnectorChannel(
      connector,
      options: const ChannelOptions(
        credentials: ChannelCredentials.insecure(),
        idleTimeout: Duration(milliseconds: 250),
      ),
    );
    final client = DesktopServiceClient(channel);
    try {
      final first = await client.getDaemonInfo(Empty());
      expect(first.version, 'niko-af-unix-test');
      expect(relay.handshakesCompleted, 1);

      // Wait longer than idleTimeout so grpc drops the idle connection; next RPC must reconnect
      // with a brand-new nonce and a second mutual HMAC handshake.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final second = await client.getDaemonInfo(Empty());
      expect(second.version, 'niko-af-unix-test');
      expect(relay.handshakesCompleted, 2);
      expect(relay.seenClientNonces.length, 2);
      expect(service.calls, 2);
    } finally {
      await channel.shutdown();
      await relay.close();
      await grpcServer.shutdown();
      dir.deleteSync(recursive: true);
    }
  });

  test('performWorkerClientHandshake preserves trailing bytes after server reply', () async {
    final dir = Directory.systemTemp.createTempSync('nk-trail-');
    final sockPath = '${dir.path}${Platform.pathSeparator}w.sock';
    final secret = generateWorkerKey();
    final trailing = utf8.encode('PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n');

    final server = await ServerSocket.bind(InternetAddress(sockPath, type: InternetAddressType.unix), 0);
    server.listen((client) async {
      final buf = BytesBuilder();
      var sentReply = false;
      final helloSize = workerHandshakeMagic.length + workerNonceSize;
      await for (final chunk in client) {
        buf.add(chunk);
        if (!sentReply && buf.length >= helloSize) {
          final all = buf.takeBytes();
          final nc = Uint8List.sublistView(all, workerHandshakeMagic.length, helloSize);
          if (all.length > helloSize) {
            buf.add(Uint8List.sublistView(all, helloSize));
          }
          final ns = generateWorkerKey();
          final sMac = computeWorkerServerMac(
            key: secret,
            clientNonce: nc,
            serverNonce: ns,
            windowPid: 10,
            workerPid: 20,
          );
          // Send Ns || MACs || trailing bytes in a single write.
          final combined = BytesBuilder()
            ..add(ns)
            ..add(sMac)
            ..add(trailing);
          client.add(combined.takeBytes());
          await client.flush();
          sentReply = true;
        }
        if (sentReply && buf.length >= workerMacSize) {
          break;
        }
      }
      await client.close();
    });

    final sock = await Socket.connect(InternetAddress(sockPath, type: InternetAddressType.unix), 0);
    try {
      final res = await performWorkerClientHandshake(
        socket: sock,
        key: secret,
        windowPid: 10,
        workerPid: 20,
      );
      final received = await res.incoming.stream.expand((c) => c).toList();
      expect(received, trailing);
      await res.subscription.cancel();
    } finally {
      sock.destroy();
      await server.close();
      dir.deleteSync(recursive: true);
    }
  });

  test('WorkerTransportConnector rejects bad server MAC and mid-handshake close without calling gRPC', () async {
    final service = _FakeDesktop();
    final grpcServer = Server.create(services: [service]);
    await grpcServer.serve(address: InternetAddress.loopbackIPv4, port: 0);
    final dir = Directory.systemTemp.createTempSync('nk-bad-');

    try {
      // 1. Corrupted server MAC.
      final badMacSock = '${dir.path}${Platform.pathSeparator}bad.sock';
      final secret = generateWorkerKey();
      final badRelay = _TestAfUnixWorkerRelay(
        socketPath: badMacSock,
        secret: secret,
        windowPid: 10,
        workerPid: 20,
        upstreamPort: grpcServer.port!,
        corruptServerMac: true,
      );
      await badRelay.start();
      final badChannel = ClientTransportConnectorChannel(
        WorkerTransportConnector(
          _FixedWorkerProcess(WorkerEndpoint(bindPath: badMacSock, secret: secret, windowPid: 10, workerPid: 20)),
        ),
        options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
      );
      try {
        await expectLater(
          DesktopServiceClient(badChannel).getDaemonInfo(Empty(), options: CallOptions(timeout: const Duration(seconds: 2))),
          throwsA(anything),
        );
        expect(service.calls, 0);
        expect(badRelay.handshakesCompleted, 0);
      } finally {
        await badChannel.terminate();
        await badRelay.close();
      }

      // 2. Server closes mid-handshake.
      final eofSock = '${dir.path}${Platform.pathSeparator}eof.sock';
      final eofRelay = _TestAfUnixWorkerRelay(
        socketPath: eofSock,
        secret: secret,
        windowPid: 10,
        workerPid: 20,
        upstreamPort: grpcServer.port!,
        closeMidHandshake: true,
      );
      await eofRelay.start();
      final eofChannel = ClientTransportConnectorChannel(
        WorkerTransportConnector(
          _FixedWorkerProcess(WorkerEndpoint(bindPath: eofSock, secret: secret, windowPid: 10, workerPid: 20)),
        ),
        options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
      );
      try {
        await expectLater(
          DesktopServiceClient(eofChannel).getDaemonInfo(Empty(), options: CallOptions(timeout: const Duration(seconds: 2))),
          throwsA(anything),
        );
        expect(service.calls, 0);
      } finally {
        await eofChannel.terminate();
        await eofRelay.close();
      }
    } finally {
      await grpcServer.shutdown();
      dir.deleteSync(recursive: true);
    }
  });

  test('WorkerTransportConnector isolates done completers across overlapping connections and restarts after consecutive failures', () async {
    final service = _FakeDesktop();
    final grpcServer = Server.create(services: [service]);
    await grpcServer.serve(address: InternetAddress.loopbackIPv4, port: 0);
    final dir = Directory.systemTemp.createTempSync('nk-b1-');
    final sockPath = '${dir.path}${Platform.pathSeparator}w.sock';
    final secret = generateWorkerKey();
    final relay = _TestAfUnixWorkerRelay(
      socketPath: sockPath,
      secret: secret,
      windowPid: 1111,
      workerPid: 2222,
      upstreamPort: grpcServer.port!,
    );
    await relay.start();

    final worker = _FixedWorkerProcess(
      WorkerEndpoint(bindPath: sockPath, secret: secret, windowPid: 1111, workerPid: 2222),
    );
    final connector = WorkerTransportConnector(worker);
    try {
      // Open connection 1 and keep it alive while opening connection 2.
      final conn1 = await connector.connect();
      final done1 = connector.done;
      final conn2 = await connector.connect();
      final done2 = connector.done;
      expect(identical(done1, done2), isFalse);
      expect(worker.handshakeSucceededCalls, 2);

      // Closing connection 1 must complete done1 without completing done2.
      await conn1.terminate();
      await done1.timeout(const Duration(seconds: 2));
      var done2Completed = false;
      unawaited(done2.then((_) => done2Completed = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(done2Completed, isFalse);

      // shutdown() tears down remaining live connection 2 and completes done2.
      connector.shutdown();
      await done2.timeout(const Duration(seconds: 2));
      await conn2.terminate();
    } finally {
      await relay.close();
      await grpcServer.shutdown();
      dir.deleteSync(recursive: true);
    }

    // Two consecutive connect failures against a non-existent socket must trigger worker.restart().
    final badWorker = _FixedWorkerProcess(
      WorkerEndpoint(bindPath: '${dir.path}${Platform.pathSeparator}missing.sock', secret: secret, windowPid: 1, workerPid: 2),
    );
    final failingConnector = WorkerTransportConnector(
      badWorker,
      connectTimeout: const Duration(milliseconds: 200),
    );
    await expectLater(failingConnector.connect(), throwsA(anything));
    expect(badWorker.restartCalls, 0);
    await expectLater(failingConnector.connect(), throwsA(anything));
    expect(badWorker.restartCalls, 1);
  });
}
