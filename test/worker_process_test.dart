import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/daemon/worker_process.dart';

class _FakeProcess implements Process {
  _FakeProcess(this.pid);

  @override
  final int pid;

  final stdoutController = StreamController<List<int>>();
  final stderrController = StreamController<List<int>>();
  final stdinChunks = <List<int>>[];
  final exitCompleter = Completer<int>();
  bool stdinClosed = false;
  bool killed = false;

  late final IOSink _stdin = IOSink(_CollectingSink(this));

  void emitStdout(String text) => stdoutController.add(utf8.encode(text));
  void emitStderr(String text) => stderrController.add(utf8.encode(text));
  void finish(int code) {
    if (!exitCompleter.isCompleted) exitCompleter.complete(code);
    if (!stdoutController.isClosed) unawaited(stdoutController.close());
    if (!stderrController.isClosed) unawaited(stderrController.close());
  }

  String get stdinText => utf8.decode(stdinChunks.expand((c) => c).toList());

  @override
  Future<int> get exitCode => exitCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    finish(-1);
    return true;
  }

  @override
  Stream<List<int>> get stderr => stderrController.stream;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => stdoutController.stream;
}

class _CollectingSink implements StreamConsumer<List<int>> {
  _CollectingSink(this.proc);
  final _FakeProcess proc;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      proc.stdinChunks.add(List<int>.from(chunk));
    }
  }

  @override
  Future<void> close() async {
    proc.stdinClosed = true;
  }
}

void main() {
  test('WorkerProcess writes 64-hex key + LF without closing stdin, parses READY, and closes stdin on dispose', () async {
    final spawned = <_FakeProcess>[];
    List<String>? capturedArgs;
    final worker = WorkerProcess(
      daemonExecutablePath: r'C:\Program Files\Niko\resources\daemon\niko-daemon.exe',
      socketDirectory: r'C:\Users\Alice\AppData\Local\Niko\run',
      windowPid: 4321,
      startProcess: (exe, args) async {
        capturedArgs = args;
        final p = _FakeProcess(9001);
        spawned.add(p);
        scheduleMicrotask(() => p.emitStdout('READY ${args.last}\n'));
        return p;
      },
    );

    final ep = await worker.ensureReady();
    expect(capturedArgs, isNotNull);
    expect(capturedArgs![0], 'worker');
    expect(capturedArgs![1], '--parent-pid');
    expect(capturedArgs![2], '4321');
    expect(capturedArgs![3], '--daemon-relay-unix');
    expect(ep.bindPath, capturedArgs![4]);
    expect(ep.windowPid, 4321);
    expect(ep.workerPid, 9001);

    final proc = spawned.single;
    expect(proc.stdinClosed, isFalse);
    expect(RegExp(r'^[0-9a-f]{64}\n$').hasMatch(proc.stdinText), isTrue);

    // Subsequent ensureReady reuses the live worker.
    expect(identical(await worker.ensureReady(), ep), isTrue);

    // Dispose closes stdin and lets the worker exit cleanly.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 10), () => proc.finish(0)));
    await worker.dispose();
    expect(proc.stdinClosed, isTrue);
    await expectLater(worker.ensureReady(), throwsStateError);
  });

  test('WorkerProcess times out when READY never arrives and backs off on restart after crash', () async {
    var launchCount = 0;
    final procs = <_FakeProcess>[];
    final worker = WorkerProcess(
      daemonExecutablePath: 'niko-daemon.exe',
      socketDirectory: '/tmp/niko-test',
      readyTimeout: const Duration(milliseconds: 60),
      initialBackoff: const Duration(milliseconds: 40),
      maxBackoff: const Duration(milliseconds: 200),
      windowPid: 100,
      startProcess: (exe, args) async {
        launchCount++;
        final p = _FakeProcess(2000 + launchCount);
        procs.add(p);
        if (launchCount == 1) {
          // Never emit READY -> triggers timeout.
          return p;
        }
        scheduleMicrotask(() => p.emitStdout('READY ${args.last}\n'));
        return p;
      },
    );

    await expectLater(worker.ensureReady(), throwsA(isA<TimeoutException>()));
    expect(procs[0].stdinClosed, isTrue);

    // Second attempt succeeds after backoff with a fresh PID and fresh secret.
    final ep2 = await worker.ensureReady();
    expect(ep2.workerPid, 2002);
    final secret2 = List<int>.from(ep2.secret);

    // Simulate unexpected worker crash -> third ensureReady restarts with a fresh secret.
    procs[1].finish(1);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ep3 = await worker.ensureReady();
    expect(ep3.workerPid, 2003);
    expect(ep3.secret, isNot(equals(secret2)));

    unawaited(Future<void>.delayed(const Duration(milliseconds: 5), () => procs[2].finish(0)));
    await worker.dispose();
  });
}
