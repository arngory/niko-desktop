import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/daemon/bootstrap.dart';

void main() {
  test('isHttp2TeardownStateError matches only grpc http2 sink close race', () {
    final matchingStack = StackTrace.fromString(
      '#0 _StreamController.add (dart:async/stream_controller.dart:617)\n'
      '#1 _StreamSinkWrapper.add (dart:async/stream_controller.dart:898)\n',
    );
    expect(
      isHttp2TeardownStateError(StateError('Cannot add event after closing'), matchingStack),
      isTrue,
    );
    expect(
      isHttp2TeardownStateError(StateError('Some other state error'), matchingStack),
      isFalse,
    );
    expect(
      isHttp2TeardownStateError(
        StateError('Cannot add event after closing'),
        StackTrace.fromString('#0 myWidget.build (package:niko/foo.dart:12)'),
      ),
      isFalse,
    );
    expect(
      isHttp2TeardownStateError(ArgumentError('Cannot add event after closing'), matchingStack),
      isFalse,
    );
  });

  test('resolveLinuxMigrationDaemonPath prefers bundled daemon then installed binary', () {
    expect(
      resolveLinuxMigrationDaemonPath(
        hasBundledDaemon: true,
        bundledDaemonPath: '/opt/niko/resources/daemon/niko-daemon',
        installedBinaryPath: '/usr/local/libexec/niko/niko-daemon',
      ),
      '/opt/niko/resources/daemon/niko-daemon',
    );
    expect(
      resolveLinuxMigrationDaemonPath(
        hasBundledDaemon: false,
        bundledDaemonPath: '',
        installedBinaryPath: '/usr/local/libexec/niko/niko-daemon',
      ),
      '/usr/local/libexec/niko/niko-daemon',
    );
    expect(
      resolveLinuxMigrationDaemonPath(
        hasBundledDaemon: false,
        bundledDaemonPath: '',
        installedBinaryPath: '',
      ),
      isNull,
    );
  });

  test('resolveLinuxUninstallDaemonPath falls back cleanly', () {
    expect(
      resolveLinuxUninstallDaemonPath(
        installedBinaryPath: '/usr/local/libexec/niko/niko-daemon',
        bundledDaemonPath: '/opt/niko/niko-daemon',
        fileExists: (p) => p == '/usr/local/libexec/niko/niko-daemon',
      ),
      '/usr/local/libexec/niko/niko-daemon',
    );
    expect(
      resolveLinuxUninstallDaemonPath(
        installedBinaryPath: '/usr/local/libexec/niko/niko-daemon',
        bundledDaemonPath: '/opt/niko/niko-daemon',
        fileExists: (_) => false,
      ),
      '/opt/niko/niko-daemon',
    );
    expect(
      resolveLinuxUninstallDaemonPath(
        installedBinaryPath: '',
        bundledDaemonPath: '',
        fileExists: (_) => false,
      ),
      '/usr/local/libexec/niko/niko-daemon',
    );
  });
}
