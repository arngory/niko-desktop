import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Shared secret size in bytes passed once over worker stdin (64 hex chars + LF).
const workerKeySize = 32;

/// Per-connection nonce size in bytes.
const workerNonceSize = 32;

/// HMAC-SHA256 output size in bytes.
const workerMacSize = 32;

/// Protocol magic bytes sent at the start of every window -> worker AF_UNIX connection.
final Uint8List workerHandshakeMagic = Uint8List.fromList(const [0x4e, 0x49, 0x4b, 0x4f, 0x57, 0x00, 0x01, 0x00]);

const _domainServer = 'niko-worker/1 server';
const _domainClient = 'niko-worker/1 client';
const _serverReplySize = workerNonceSize + workerMacSize;

/// Generates a cryptographically secure 32-byte worker handshake key.
Uint8List generateWorkerKey() {
  final rng = Random.secure();
  return Uint8List.fromList(List<int>.generate(workerKeySize, (_) => rng.nextInt(256)));
}

const _hexDigits = [
  0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
  0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66,
];

/// Encodes a 32-byte key as 64 lowercase ASCII hex bytes terminated by LF (`0x0a`).
/// Using a mutable byte buffer allows callers to zero it right after flushing to stdin.
Uint8List encodeWorkerKeyBytes(Uint8List key) {
  if (key.length != workerKeySize) {
    throw ArgumentError.value(key.length, 'key.length', 'must be $workerKeySize bytes');
  }
  final out = Uint8List(workerKeySize * 2 + 1);
  for (var i = 0; i < workerKeySize; i++) {
    final byte = key[i];
    out[i * 2] = _hexDigits[byte >> 4];
    out[i * 2 + 1] = _hexDigits[byte & 0x0f];
  }
  out[workerKeySize * 2] = 0x0a;
  return out;
}

/// Encodes a 32-byte key as 64 lowercase hex characters terminated by LF (`\n`).
String encodeWorkerKeyLine(Uint8List key) => ascii.decode(encodeWorkerKeyBytes(key));

/// Computes the domain-separated transcript-bound HMAC-SHA256 tag matching
/// `experimental/boxdd/worker_handshake.go:computeWorkerMAC`.
Uint8List computeWorkerMac({
  required Uint8List key,
  required String domain,
  required List<int> clientNonce,
  required List<int> serverNonce,
  required int windowPid,
  required int workerPid,
}) {
  final pids = ByteData(8)
    ..setUint32(0, windowPid, Endian.little)
    ..setUint32(4, workerPid, Endian.little);
  final input = BytesBuilder(copy: false)
    ..add(utf8.encode(domain))
    ..add(clientNonce)
    ..add(serverNonce)
    ..add(pids.buffer.asUint8List());
  return Uint8List.fromList(Hmac(sha256, key).convert(input.takeBytes()).bytes);
}

/// Computes the server-to-client MAC for the worker handshake.
Uint8List computeWorkerServerMac({
  required Uint8List key,
  required List<int> clientNonce,
  required List<int> serverNonce,
  required int windowPid,
  required int workerPid,
}) =>
    computeWorkerMac(
      key: key,
      domain: _domainServer,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
      windowPid: windowPid,
      workerPid: workerPid,
    );

/// Computes the client-to-server MAC for the worker handshake.
Uint8List computeWorkerClientMac({
  required Uint8List key,
  required List<int> clientNonce,
  required List<int> serverNonce,
  required int windowPid,
  required int workerPid,
}) =>
    computeWorkerMac(
      key: key,
      domain: _domainClient,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
      windowPid: windowPid,
      workerPid: workerPid,
    );

/// Constant-time byte slice equality.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Result of a completed client-side worker handshake on [socket]: [incoming] delivers any trailing
/// HTTP/2 bytes received right after the handshake reply followed by all subsequent socket chunks.
class WorkerHandshakeResult {
  const WorkerHandshakeResult({required this.incoming, required this.subscription});

  final StreamController<List<int>> incoming;
  final StreamSubscription<Uint8List> subscription;
}

/// Performs the client half of the mutual HMAC-SHA256 handshake over [socket] before any HTTP/2 bytes
/// are sent:
///   1. C -> S: `NIKOW\x00\x01\x00` (8 B) || Nc (32 B)
///   2. S -> C: Ns (32 B) || MACs (32 B)
///   3. C verifies MACs in constant time before sending MACc (32 B).
Future<WorkerHandshakeResult> performWorkerClientHandshake({
  required Socket socket,
  required Uint8List key,
  required int windowPid,
  required int workerPid,
  Duration timeout = const Duration(seconds: 5),
  @visibleForTesting Uint8List? clientNonceOverride,
  void Function()? onClosed,
}) async {
  final clientNonce = clientNonceOverride ?? generateWorkerKey();
  if (clientNonce.length != workerNonceSize) {
    throw ArgumentError.value(clientNonce.length, 'clientNonce', 'must be $workerNonceSize bytes');
  }

  final incoming = StreamController<List<int>>();
  final replyCompleter = Completer<Uint8List>();
  // Avoid unhandled async error if flush() fails before awaiting replyCompleter.future.
  replyCompleter.future.ignore();
  final buffer = BytesBuilder(copy: false);
  var handshakeDone = false;

  final subscription = socket.listen(
    (chunk) {
      if (handshakeDone) {
        if (!incoming.isClosed) incoming.add(chunk);
        return;
      }
      buffer.add(chunk);
      if (buffer.length >= _serverReplySize) {
        final all = buffer.takeBytes();
        handshakeDone = true;
        final reply = Uint8List.sublistView(all, 0, _serverReplySize);
        if (all.length > _serverReplySize && !incoming.isClosed) {
          incoming.add(Uint8List.sublistView(all, _serverReplySize));
        }
        if (!replyCompleter.isCompleted) replyCompleter.complete(reply);
      }
    },
    onError: (Object error, StackTrace stack) {
      if (!replyCompleter.isCompleted) {
        replyCompleter.completeError(error, stack);
      } else if (!incoming.isClosed) {
        incoming.addError(error, stack);
      }
    },
    onDone: () {
      if (!replyCompleter.isCompleted) {
        replyCompleter.completeError(const SocketException('worker closed socket during handshake'));
      }
      if (!incoming.isClosed) unawaited(incoming.close());
      onClosed?.call();
    },
    cancelOnError: false,
  );
  incoming.onPause = subscription.pause;
  incoming.onResume = subscription.resume;
  incoming.onCancel = subscription.cancel;

  try {
    await (() async {
      final hello = BytesBuilder(copy: false)
        ..add(workerHandshakeMagic)
        ..add(clientNonce);
      socket.add(hello.takeBytes());
      await socket.flush();

      final serverReply = await replyCompleter.future;
      final serverNonce = Uint8List.sublistView(serverReply, 0, workerNonceSize);
      final serverMac = Uint8List.sublistView(serverReply, workerNonceSize, _serverReplySize);
      final expectedServerMac = computeWorkerServerMac(
        key: key,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        windowPid: windowPid,
        workerPid: workerPid,
      );
      if (!constantTimeEquals(serverMac, expectedServerMac)) {
        throw const SocketException('worker server MAC mismatch');
      }

      final clientMac = computeWorkerClientMac(
        key: key,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        windowPid: windowPid,
        workerPid: workerPid,
      );
      socket.add(clientMac);
      await socket.flush();
    })().timeout(timeout);

    return WorkerHandshakeResult(incoming: incoming, subscription: subscription);
  } catch (_) {
    await subscription.cancel();
    if (!incoming.isClosed) await incoming.close();
    socket.destroy();
    rethrow;
  }
}
