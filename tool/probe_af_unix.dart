// AF_UNIX release-transport probe (desktop-stage3.md, decision 8):
//
// Tests the window <-> worker link on Windows and Linux without FFI:
//   - Dart spawns the Go probe listener (tool/probe_af_unix) and passes a 32-byte secret over stdin;
//   - Go verifies the socket parent directory is a real directory owned by the current user and applies
//     user-only permissions (protected DACL on Windows, 0700 on Unix);
//   - Go checks socket path UTF-8 length (<= 107 bytes, with Windows 8.3 fallback), refuses to delete
//     non-socket files, removes only a genuine stale AF_UNIX socket, binds AF_UNIX, and verifies socket owner;
//   - Go checks peer PID (SIO_AF_UNIX_GETPEERPID on Windows ignoring bytesReturned == 0, SO_PEERCRED on Linux)
//     and rejects any process other than its parent;
//   - before any HTTP/2 bytes leave Dart, ClientTransportConnector performs a mutual transcript-bound
//     HMAC-SHA256 handshake (clientNonce -> serverNonce||s2c MAC -> c2s MAC), verified in constant time
//     by both sides;
//   - Go then relays raw bytes to a local gRPC server (DesktopService), and Dart invokes GetDaemonInfo over
//     ClientTransportConnectorChannel with ASCII :authority = "localhost".
//
// Usage:
//   NIKO_AF_UNIX_PROBE=<path to probe-af-unix binary> dart run tool/probe_af_unix.dart
//   dart run tool/probe_af_unix.dart --worker <path>
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// Transitive dependencies locked via package:grpc in pubspec.lock (kept out of pubspec.yaml for the probe).
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart';
import 'package:grpc/grpc.dart';
// ignore: depend_on_referenced_packages
import 'package:http2/transport.dart' as http2;
import 'package:niko_desktop/gen/experimental/boxdd/desktop_service.pbgrpc.dart';
import 'package:protobuf/well_known_types/google/protobuf/empty.pb.dart';

const _secretSize = 32;
const _nonceSize = 32;
const _macSize = 32;
const _serverReplySize = _nonceSize + _macSize;
const _domainS2C = 'niko-worker-v1:s2c:';
const _domainC2S = 'niko-worker-v1:c2s:';

Uint8List _randomBytes(int length) {
  final rng = Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => rng.nextInt(256)));
}

Uint8List _computeMac(Uint8List secret, String domain, List<int> clientNonce, List<int> serverNonce) {
  final hmac = Hmac(sha256, secret);
  final input = BytesBuilder(copy: false)
    ..add(utf8.encode(domain))
    ..add(clientNonce)
    ..add(serverNonce);
  return Uint8List.fromList(hmac.convert(input.takeBytes()).bytes);
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Custom gRPC transport over an AF_UNIX socket with a pre-HTTP/2 mutual HMAC-SHA256 handshake.
class UnixWorkerTransportConnector implements ClientTransportConnector {
  UnixWorkerTransportConnector({
    required this.socketPath,
    required this.secret,
    this.handshakeTimeout = const Duration(seconds: 5),
  });

  final String socketPath;
  final Uint8List secret;
  final Duration handshakeTimeout;

  Completer<void> _done = Completer<void>();
  Socket? _socket;

  @override
  String get authority => 'localhost';

  @override
  Future<void> get done => _done.future;

  @override
  Future<http2.ClientTransportConnection> connect() async {
    if (_done.isCompleted) {
      _done = Completer<void>();
    }
    final activeDone = _done;
    final address = InternetAddress(socketPath, type: InternetAddressType.unix);
    final socket = await Socket.connect(address, 0, timeout: handshakeTimeout);
    _socket = socket;

    final incoming = StreamController<List<int>>();
    final handshake = Completer<Uint8List>();
    // Prevent uncaught async errors if flush() fails before awaiting handshake.future.
    handshake.future.ignore();
    final buf = BytesBuilder(copy: false);
    var handshakeDone = false;

    late final StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (chunk) {
        if (handshakeDone) {
          if (!incoming.isClosed) incoming.add(chunk);
          return;
        }
        buf.add(chunk);
        if (buf.length >= _serverReplySize) {
          final all = buf.takeBytes();
          handshakeDone = true;
          final reply = Uint8List.sublistView(all, 0, _serverReplySize);
          if (all.length > _serverReplySize && !incoming.isClosed) {
            incoming.add(Uint8List.sublistView(all, _serverReplySize));
          }
          handshake.complete(reply);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!handshake.isCompleted) {
          handshake.completeError(error, stackTrace);
        } else if (!incoming.isClosed) {
          incoming.addError(error, stackTrace);
        }
      },
      onDone: () {
        if (!handshake.isCompleted) {
          handshake.completeError(const SocketException('worker closed before completing handshake'));
        }
        if (!incoming.isClosed) unawaited(incoming.close());
        if (handshakeDone && !activeDone.isCompleted) activeDone.complete();
      },
    );
    incoming.onCancel = sub.cancel;
    incoming.onPause = sub.pause;
    incoming.onResume = sub.resume;

    try {
      final clientNonce = _randomBytes(_nonceSize);
      socket.add(clientNonce);
      await socket.flush();

      final reply = await handshake.future.timeout(handshakeTimeout);
      final serverNonce = Uint8List.sublistView(reply, 0, _nonceSize);
      final serverMac = Uint8List.sublistView(reply, _nonceSize, _serverReplySize);
      final expectedServerMac = _computeMac(secret, _domainS2C, clientNonce, serverNonce);
      if (!_constantTimeEquals(serverMac, expectedServerMac)) {
        throw const SocketException('worker handshake MAC mismatch');
      }

      // Prove knowledge of the secret back to the worker before HTTP/2 starts.
      final clientMac = _computeMac(secret, _domainC2S, clientNonce, serverNonce);
      socket.add(clientMac);
      await socket.flush();
    } catch (_) {
      await sub.cancel();
      if (!incoming.isClosed) await incoming.close();
      socket.destroy();
      rethrow;
    }

    return http2.ClientTransportConnection.viaStreams(incoming.stream, socket);
  }

  @override
  Future<void> shutdown() async {
    _socket?.destroy();
    if (!_done.isCompleted) _done.complete();
  }
}

class _ProbeDesktopService extends DesktopServiceBase {
  int calls = 0;
  String? lastAuthority;

  @override
  Future<DaemonInfo> getDaemonInfo(ServiceCall call, Empty request) async {
    calls++;
    lastAuthority = call.clientMetadata?[':authority'];
    return DaemonInfo(version: 'probe-ok', ownership: DaemonOwnership.DAEMON_OWNERSHIP_AVAILABLE);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw GrpcError.unimplemented();
}

class _RunningWorker {
  _RunningWorker(this.process, this.bindPath, this.stderrLines, this.stderrDone);

  final Process process;
  final String bindPath;
  final List<String> stderrLines;
  final Future<void> stderrDone;

  Future<void> stop() async {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    });
    await stderrDone.timeout(const Duration(seconds: 2), onTimeout: () {});
  }
}

Future<_RunningWorker> _startWorker({
  required String workerBin,
  required String socketPath,
  required int upstreamPort,
  required Uint8List secret,
}) async {
  final args = [
    '--socket',
    socketPath,
    '--upstream',
    '127.0.0.1:$upstreamPort',
  ];
  final process = await Process.start(workerBin, args);
  final stderrLines = <String>[];
  final stderrDone = Completer<void>();
  process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
    stderrLines.add,
    onDone: () {
      if (!stderrDone.isCompleted) stderrDone.complete();
    },
  );

  final ready = Completer<String>();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (line.startsWith('READY ') && !ready.isCompleted) {
        ready.complete(line.substring('READY '.length));
      }
    },
    onDone: () async {
      if (!ready.isCompleted) {
        await stderrDone.future.timeout(const Duration(seconds: 2), onTimeout: () {});
        final exit = await process.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);
        ready.completeError(StateError('worker exited ($exit) before READY: ${stderrLines.join(' | ')}'));
      }
    },
  );

  process.stdin.add(secret);
  await process.stdin.flush();
  await process.stdin.close();

  final bindPath = await ready.future.timeout(const Duration(seconds: 10));
  return _RunningWorker(process, bindPath, stderrLines, stderrDone.future);
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

String _resolveWorkerBinary(List<String> arguments) {
  for (var i = 0; i + 1 < arguments.length; i++) {
    if (arguments[i] == '--worker') return arguments[i + 1];
  }
  final env = Platform.environment['NIKO_AF_UNIX_PROBE'] ?? '';
  if (env.isNotEmpty) return env;
  throw StateError('pass --worker <path> or set NIKO_AF_UNIX_PROBE');
}

Future<void> _verifyGrpcCall({
  required String label,
  required String workerBin,
  required String socketPath,
  required int upstreamPort,
  required _ProbeDesktopService service,
  bool testRoguePeer = false,
  bool testSecondConnectionRefused = false,
}) async {
  final secret = _randomBytes(_secretSize);
  final callsBefore = service.calls;
  final worker = await _startWorker(
    workerBin: workerBin,
    socketPath: socketPath,
    upstreamPort: upstreamPort,
    secret: secret,
  );
  try {
    // On Windows AF_UNIX sockets are reparse points: check typeSync(followLinks: false) rather than File.existsSync.
    final entityType = FileSystemEntity.typeSync(worker.bindPath, followLinks: false);
    stdout.writeln('[$label] bound=${worker.bindPath} (${utf8.encode(worker.bindPath).length} UTF-8 B), '
        'typeSync(noFollow)=$entityType, existsSync=${File(worker.bindPath).existsSync()}');
    _expect(entityType != FileSystemEntityType.notFound, '$label: socket not visible via typeSync(followLinks: false)');

    if (testRoguePeer) {
      // Spawn a separate process (PID != this process's PID) and verify the worker rejects it by peer PID.
      final rogue = await Process.run(workerBin, ['--connect', worker.bindPath]);
      final rogueOut = '${rogue.stdout}'.trim();
      stdout.writeln('[$label] rogue peer exit=${rogue.exitCode}: $rogueOut');
      _expect(rogue.exitCode == 0, '$label: rogue peer was not rejected: ${rogue.stderr}');
      _expect(rogueOut.contains('REJECTED'), '$label: rogue peer output missing REJECTED: $rogueOut');
    }

    final connector = UnixWorkerTransportConnector(socketPath: worker.bindPath, secret: secret);
    final channel = ClientTransportConnectorChannel(
      connector,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    try {
      final client = DesktopServiceClient(channel);
      final info = await client.getDaemonInfo(Empty(), options: CallOptions(timeout: const Duration(seconds: 5)));
      _expect(info.version == 'probe-ok', '$label: unexpected version ${info.version}');
      _expect(service.calls == callsBefore + 1, '$label: expected 1 gRPC call');
      _expect(service.lastAuthority == 'localhost', '$label: authority was ${service.lastAuthority}, want localhost');

      if (testSecondConnectionRefused) {
        var secondConnected = false;
        try {
          final second = await Socket.connect(
            InternetAddress(worker.bindPath, type: InternetAddressType.unix),
            0,
            timeout: const Duration(seconds: 2),
          );
          secondConnected = true;
          second.destroy();
        } on SocketException {
          // Expected: listener closed immediately after accepting the single authorized peer.
        }
        _expect(!secondConnected, '$label: second connection to single-use worker should fail');
        stdout.writeln('[$label] second connection refused as expected');
      }
    } finally {
      await channel.shutdown();
    }

    final workerExit = await worker.process.exitCode.timeout(const Duration(seconds: 5));
    await worker.stderrDone.timeout(const Duration(seconds: 2), onTimeout: () {});
    for (final line in worker.stderrLines) {
      stdout.writeln('[$label] worker: $line');
    }
    _expect(workerExit == 0, '$label: worker exited with code $workerExit');
    stdout.writeln('[$label] PASS');
  } finally {
    await worker.stop();
  }
}

Future<void> main(List<String> arguments) async {
  // Cross-check mutual HMAC-SHA256 vectors shared with tool/probe_af_unix/main_test.go.
  final vecSecret = Uint8List.fromList(List<int>.generate(_secretSize, (i) => i));
  final vecClientNonce = Uint8List.fromList(List<int>.generate(_nonceSize, (i) => 0x40 + i));
  final vecServerNonce = Uint8List.fromList(List<int>.generate(_nonceSize, (i) => 0x80 + i));
  final s2cHex = _computeMac(vecSecret, _domainS2C, vecClientNonce, vecServerNonce)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final c2sHex = _computeMac(vecSecret, _domainC2S, vecClientNonce, vecServerNonce)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  _expect(s2cHex != c2sHex, 's2c and c2s MACs must differ');
  _expect(
    s2cHex == '685a53102f14e134c8195d5554a2c18acde622c1927e18fcc6f1e6606e2dc49f' &&
        c2sHex == '4c63b67d5dbb4102ed8e8cd30c2def1c57c8b0cfc1a113ea271263ad4d04e6b4',
    'HMAC-SHA256 vectors mismatch: s2c=$s2cHex c2s=$c2sHex',
  );

  final workerBin = _resolveWorkerBinary(arguments);
  _expect(File(workerBin).existsSync(), 'worker binary not found at $workerBin');

  stdout.writeln('AF_UNIX probe on ${Platform.operatingSystem} ${Platform.operatingSystemVersion}, '
      'Dart ${Platform.version.split(' ').first}, pid=$pid');

  final service = _ProbeDesktopService();
  final server = Server.create(services: [service]);
  await server.serve(address: '127.0.0.1', port: 0);
  final upstreamPort = server.port!;

  final root = Directory.systemTemp.createTempSync('nk-');
  try {
    // 1. ASCII path + rogue sibling PID rejection + single-connection enforcement.
    final asciiPath = '${root.path}${Platform.pathSeparator}a${Platform.pathSeparator}w.sock';
    await _verifyGrpcCall(
      label: 'ascii+pid+single',
      workerBin: workerBin,
      socketPath: asciiPath,
      upstreamPort: upstreamPort,
      service: service,
      testRoguePeer: true,
      testSecondConnectionRefused: true,
    );

    // 2. Path with Cyrillic and spaces + genuine stale socket cleanup.
    final cyrillicDir = Directory('${root.path}${Platform.pathSeparator}тест юзер${Platform.pathSeparator}niko проба')
      ..createSync(recursive: true);
    final cyrillicPath = '${cyrillicDir.path}${Platform.pathSeparator}w.sock';
    final staleRes = await Process.run(workerBin, ['--leave-stale', cyrillicPath]);
    _expect(staleRes.exitCode == 0, 'leave-stale failed: ${staleRes.stderr}');
    await _verifyGrpcCall(
      label: 'cyrillic+spaces+stale',
      workerBin: workerBin,
      socketPath: cyrillicPath,
      upstreamPort: upstreamPort,
      service: service,
    );

    // 3. Non-socket regular file at socket path must be refused, not clobbered.
    final regularPath = '${root.path}${Platform.pathSeparator}r${Platform.pathSeparator}not-a-sock';
    File(regularPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('keep-me');
    String? nonSocketError;
    try {
      final w = await _startWorker(
        workerBin: workerBin,
        socketPath: regularPath,
        upstreamPort: upstreamPort,
        secret: _randomBytes(_secretSize),
      );
      await w.stop();
    } on StateError catch (error) {
      nonSocketError = error.message;
    }
    _expect(nonSocketError != null, 'non-socket-refusal: worker unexpectedly started over a regular file');
    _expect(nonSocketError!.contains('non-socket file'), 'unexpected error: $nonSocketError');
    _expect(File(regularPath).existsSync(), 'regular file was deleted');
    stdout.writeln('[non-socket-refusal] PASS');

    // 4. Wrong secret: Dart must reject in constant time BEFORE sending clientMAC or HTTP/2.
    final wrongSecretPath = '${root.path}${Platform.pathSeparator}b${Platform.pathSeparator}w.sock';
    final workerSecret = _randomBytes(_secretSize);
    final clientSecret = _randomBytes(_secretSize);
    final callsBefore = service.calls;
    final worker = await _startWorker(
      workerBin: workerBin,
      socketPath: wrongSecretPath,
      upstreamPort: upstreamPort,
      secret: workerSecret,
    );
    try {
      final connector = UnixWorkerTransportConnector(socketPath: worker.bindPath, secret: clientSecret);
      final channel = ClientTransportConnectorChannel(
        connector,
        options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
      );
      var failed = false;
      try {
        await DesktopServiceClient(channel).getDaemonInfo(
          Empty(),
          options: CallOptions(timeout: const Duration(seconds: 3)),
        );
      } catch (error) {
        failed = true;
        stdout.writeln('[wrong-secret] rejected before gRPC as expected: $error');
      } finally {
        await channel.shutdown();
      }
      _expect(failed, 'wrong-secret: call unexpectedly succeeded');
      _expect(service.calls == callsBefore, 'wrong-secret: gRPC server received a call despite bad MAC');
      stdout.writeln('[wrong-secret] PASS (0 gRPC calls reached server)');
    } finally {
      await worker.stop();
    }

    // 5. Path exceeding 107 UTF-8 bytes: Windows 8.3 fallback or explicit diagnostic error.
    final longDir = Directory(
      '${root.path}${Platform.pathSeparator}Очень Длинное Имя Пользователя С Пробелами Для Проверки Лимита Пути',
    )..createSync(recursive: true);
    final longPath = '${longDir.path}${Platform.pathSeparator}w.sock';
    final longBytes = utf8.encode(longPath).length;
    _expect(longBytes > 107, 'long-path test path was only $longBytes UTF-8 bytes');
    try {
      await _verifyGrpcCall(
        label: 'long-path-8.3',
        workerBin: workerBin,
        socketPath: longPath,
        upstreamPort: upstreamPort,
        service: service,
      );
      stdout.writeln('[long-path-8.3] PASS via 8.3 short path fallback ($longBytes -> <=107 bytes)');
    } on StateError catch (error) {
      // Expected when 8.3 short names are disabled on the volume (or on Linux).
      final msg = error.message;
      _expect(msg.contains('limit 107'), 'long-path unexpected error: $msg');
      stdout.writeln('[long-path-8.3] PASS explicit limit diagnostic (8.3 unavailable): $msg');
    }

    stdout.writeln('ALL AF_UNIX PROBE CHECKS PASSED');
  } finally {
    await server.shutdown();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort cleanup on Windows.
    }
  }
}
