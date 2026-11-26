import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'worker_handshake.dart';

/// Active connection parameters for a running AF_UNIX worker child process.
class WorkerEndpoint {
  const WorkerEndpoint({
    required this.bindPath,
    required this.secret,
    required this.windowPid,
    required this.workerPid,
  });

  /// Exact path printed by the worker's `READY <bindPath>` line (may be an 8.3 short path on Windows).
  final String bindPath;
  final Uint8List secret;
  final int windowPid;
  final int workerPid;
}

typedef WorkerProcessStarter = Future<Process> Function(String executable, List<String> arguments);

/// Manages the lifecycle of `niko-daemon.exe worker --parent-pid <pid> --daemon-relay-unix <path>`.
///
/// The worker is spawned as a direct child of this window process, receives a fresh 32-byte shared
/// key over stdin (without closing stdin, whose EOF signals the worker to exit), and stays running
/// across gRPC reconnects. If the worker exits unexpectedly, [ensureReady] restarts it with a fresh
/// key after exponential backoff (1s -> 30s).
class WorkerProcess {
  WorkerProcess({
    required this.daemonExecutablePath,
    this.socketDirectory,
    this.userMode = false,
    this.workingDirectory,
    this.readyTimeout = const Duration(seconds: 20),
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    int? windowPid,
    WorkerProcessStarter? startProcess,
    DateTime Function()? now,
  })  : _windowPid = windowPid ?? pid,
        _startProcess = startProcess ?? ((exe, args) => Process.start(exe, args)),
        _now = now ?? DateTime.now;

  final String daemonExecutablePath;
  final String? socketDirectory;
  final bool userMode;
  final String? workingDirectory;
  final Duration readyTimeout;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final int _windowPid;
  final WorkerProcessStarter _startProcess;
  final DateTime Function() _now;

  Process? _process;
  WorkerEndpoint? _endpoint;
  Future<WorkerEndpoint>? _starting;
  bool _disposed = false;
  bool _handshakeSucceededForCurrent = false;
  int _consecutiveFailures = 0;
  DateTime? _nextStartAllowedAt;

  /// Resolves `<exeDir>\resources\daemon\niko-daemon.exe` next to the running window executable.
  static String defaultDaemonPath({String? resolvedExecutable}) {
    final exeDir = File(resolvedExecutable ?? Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    return '$exeDir${sep}resources${sep}daemon${sep}niko-daemon.exe';
  }

  /// Resolves `%LOCALAPPDATA%\Niko\run` on Windows (or system temp fallback for tests).
  static String defaultSocketDirectory({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final localAppData = env['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return '$localAppData\\Niko\\run';
    }
    final sep = Platform.pathSeparator;
    return '${Directory.systemTemp.path}${sep}niko-run';
  }

  /// Returns the active [WorkerEndpoint], starting or restarting the worker child if needed.
  Future<WorkerEndpoint> ensureReady() {
    if (_disposed) {
      return Future.error(StateError('WorkerProcess is disposed'));
    }
    final current = _endpoint;
    if (current != null && _process != null) {
      return Future.value(current);
    }
    return _starting ??= _startWithBackoff().whenComplete(() {
      _starting = null;
    });
  }

  /// Marks the active worker endpoint as failed (e.g. if the socket unexpectedly disappeared) so the
  /// next [ensureReady] restarts it cleanly.
  Future<void> restart() async {
    await _stopProcess();
  }

  /// Resets restart backoff after an actual client <-> worker mutual HMAC handshake succeeds,
  /// preventing tight crash loops where the worker prints READY and immediately dies.
  void markHandshakeSucceeded() {
    _handshakeSucceededForCurrent = true;
    _consecutiveFailures = 0;
    _nextStartAllowedAt = null;
  }

  void _recordFailure() {
    _consecutiveFailures++;
    final backoffMs = min(
      maxBackoff.inMilliseconds,
      initialBackoff.inMilliseconds * (1 << min(_consecutiveFailures - 1, 10)),
    );
    _nextStartAllowedAt = _now().add(Duration(milliseconds: backoffMs));
  }

  Future<WorkerEndpoint> _startWithBackoff() async {
    final allowAt = _nextStartAllowedAt;
    if (allowAt != null) {
      final wait = allowAt.difference(_now());
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
    }
    if (_disposed) {
      throw StateError('WorkerProcess is disposed');
    }

    try {
      return await _spawnOnce();
    } catch (_) {
      _recordFailure();
      rethrow;
    }
  }

  Future<WorkerEndpoint> _spawnOnce() async {
    final dir = socketDirectory ?? defaultSocketDirectory();
    final rng = Random.secure();
    final idHex = List<int>.generate(8, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final sep = Platform.pathSeparator;
    final socketPath = '$dir${sep}w-$idHex.sock';
    final secret = generateWorkerKey();

    final proc = await _startProcess(daemonExecutablePath, [
      'worker',
      if (userMode) '--user-mode',
      if (workingDirectory != null && workingDirectory!.isNotEmpty) ...[
        '--working-directory',
        workingDirectory!,
      ],
      '--parent-pid',
      '$_windowPid',
      '--daemon-relay-unix',
      socketPath,
    ]);
    // Avoid unhandled async errors if the worker exits and breaks stdin later.
    proc.stdin.done.ignore();

    final ready = Completer<String>();
    ready.future.ignore();
    final stderrLines = <String>[];

    final stdoutSub = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        if (!ready.isCompleted && line.startsWith('READY ')) {
          final bindPath = line.substring('READY '.length).trim();
          if (bindPath.isNotEmpty) {
            ready.complete(bindPath);
          }
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!ready.isCompleted) ready.completeError(error, stack);
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(StateError('worker exited before READY: ${stderrLines.join(' | ')}'));
        }
      },
    );

    final stderrSub = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (stderrLines.length < 16) stderrLines.add(line);
    });

    try {
      final keyBytes = encodeWorkerKeyBytes(secret);
      try {
        proc.stdin.add(keyBytes);
        await proc.stdin.flush().timeout(readyTimeout);
      } finally {
        _zeroSecret(keyBytes);
      }

      final bindPath = await ready.future.timeout(
        readyTimeout,
        onTimeout: () => throw TimeoutException('worker did not signal READY within $readyTimeout'),
      );

      if (_disposed) {
        await _terminateProcess(proc);
        await stdoutSub.cancel();
        await stderrSub.cancel();
        throw StateError('WorkerProcess is disposed');
      }

      final endpoint = WorkerEndpoint(
        bindPath: bindPath,
        secret: secret,
        windowPid: _windowPid,
        workerPid: proc.pid,
      );
      _process = proc;
      _endpoint = endpoint;
      _handshakeSucceededForCurrent = false;

      unawaited(proc.exitCode.then((_) {
        if (_process == proc) {
          _process = null;
          _endpoint = null;
          _zeroSecret(secret);
          if (!_disposed && !_handshakeSucceededForCurrent) {
            _recordFailure();
          }
        }
        unawaited(stdoutSub.cancel());
        unawaited(stderrSub.cancel());
      }));

      return endpoint;
    } catch (_) {
      _zeroSecret(secret);
      await _terminateProcess(proc);
      await stdoutSub.cancel();
      await stderrSub.cancel();
      rethrow;
    }
  }

  Future<void> _stopProcess() async {
    final proc = _process;
    final ep = _endpoint;
    _process = null;
    _endpoint = null;
    if (ep != null) {
      _zeroSecret(ep.secret);
    }
    if (proc != null) {
      await _terminateProcess(proc);
    }
  }

  Future<void> _terminateProcess(Process proc) async {
    try {
      await proc.stdin.close();
    } catch (_) {
      // Stdin may already be closed.
    }
    try {
      await proc.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      proc.kill();
      await proc.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);
    }
  }

  static void _zeroSecret(Uint8List secret) {
    for (var i = 0; i < secret.length; i++) {
      secret[i] = 0;
    }
  }

  /// Shuts down the worker child cleanly by closing its stdin pipe.
  Future<void> dispose() async {
    _disposed = true;
    final inFlight = _starting;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
    }
    await _stopProcess();
  }
}
