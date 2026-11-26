import 'dart:async';
import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart' as http2;

import 'worker_handshake.dart';
import 'worker_process.dart';

class _LiveConnection {
  _LiveConnection({
    required this.socket,
    required this.subscription,
    required this.incoming,
    required this.done,
  });

  final Socket socket;
  final StreamSubscription<List<int>> subscription;
  final StreamController<List<int>> incoming;
  final Completer<void> done;

  void close() {
    unawaited(subscription.cancel());
    if (!incoming.isClosed) {
      unawaited(incoming.close());
    }
    socket.destroy();
    if (!done.isCompleted) done.complete();
  }
}

/// gRPC [ClientTransportConnector] that connects to a local AF_UNIX worker socket and performs
/// a fresh mutual HMAC-SHA256 handshake on every connection (including reconnects after idle timeout).
class WorkerTransportConnector implements ClientTransportConnector {
  WorkerTransportConnector(
    this._worker, {
    this.connectTimeout = const Duration(seconds: 3),
    this.handshakeTimeout = const Duration(seconds: 5),
  });

  final WorkerProcess _worker;
  final Duration connectTimeout;
  final Duration handshakeTimeout;

  Completer<void> _done = Completer<void>();
  final Set<_LiveConnection> _live = {};
  int _consecutiveFailures = 0;

  @override
  String get authority => 'localhost';

  @override
  Future<void> get done => _done.future;

  @override
  Future<http2.ClientTransportConnection> connect() async {
    // Allocate a fresh completer per connection so a draining previous connection
    // finishing asynchronously can never abandon a newer healthy connection.
    final connDone = Completer<void>();
    _done = connDone;

    final endpoint = await _worker.ensureReady();
    Socket? socket;
    try {
      final address = InternetAddress(endpoint.bindPath, type: InternetAddressType.unix);
      socket = await Socket.connect(address, 0, timeout: connectTimeout);
      final result = await performWorkerClientHandshake(
        socket: socket,
        key: endpoint.secret,
        windowPid: endpoint.windowPid,
        workerPid: endpoint.workerPid,
        timeout: handshakeTimeout,
        onClosed: () {
          if (!connDone.isCompleted) connDone.complete();
        },
      );
      _consecutiveFailures = 0;
      _worker.markHandshakeSucceeded();

      final live = _LiveConnection(
        socket: socket,
        subscription: result.subscription,
        incoming: result.incoming,
        done: connDone,
      );
      _live.add(live);
      unawaited(socket.done.catchError((Object _) {}).whenComplete(() {
        _live.remove(live);
        if (!connDone.isCompleted) connDone.complete();
      }));
      return http2.ClientTransportConnection.viaStreams(result.incoming.stream, socket);
    } catch (_) {
      socket?.destroy();
      if (!connDone.isCompleted) connDone.complete();
      _consecutiveFailures++;
      if (_consecutiveFailures >= 2) {
        _consecutiveFailures = 0;
        unawaited(_worker.restart());
      }
      rethrow;
    }
  }

  @override
  void shutdown() {
    for (final live in _live.toList()) {
      live.close();
    }
    _live.clear();
    if (!_done.isCompleted) _done.complete();
  }
}
