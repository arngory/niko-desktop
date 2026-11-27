import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/daemon/locator.dart';
import 'package:niko_desktop/platform/autostart.dart';

void main() {
  group('macOS base paths', () {
    test('defaultMacosUserSocketPath and defaultMacosUserDataDir use HOME', () {
      const env = {'HOME': '/Users/alice'};
      expect(
        defaultMacosUserSocketPath(environment: env),
        '/Users/alice/Library/Caches/Niko/niko-daemon.sock',
      );
      expect(
        defaultMacosUserDataDir(environment: env),
        '/Users/alice/Library/Application Support/Niko/user-daemon',
      );
      expect(defaultMacosUserSocketPath(environment: const {}), isNull);
      expect(defaultMacosUserDataDir(environment: const {}), isNull);
    });

    test('defaultMacosBundledDaemonPath prefers .app/Contents/Resources then sibling resources', () {
      const exe = '/Applications/Niko.app/Contents/MacOS/Niko';
      const appResource = '/Applications/Niko.app/Contents/Resources/daemon/niko-daemon';
      const sibling = '/Applications/Niko.app/Contents/MacOS/resources/daemon/niko-daemon';

      expect(
        defaultMacosBundledDaemonPath(
          resolvedExecutable: exe,
          fileExists: (p) => p == appResource,
        ),
        appResource,
      );
      expect(
        defaultMacosBundledDaemonPath(
          resolvedExecutable: exe,
          fileExists: (p) => p == sibling,
        ),
        sibling,
      );
      expect(
        defaultMacosBundledDaemonPath(
          resolvedExecutable: exe,
          fileExists: (_) => false,
        ),
        appResource,
      );
    });
  });

  group('macOS LaunchAgent autostart', () {
    test('creates, reads, escapes XML, and deletes LaunchAgent plist', () async {
      final tmp = Directory.systemTemp.createTempSync('niko-macos-autostart-');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final autostart = DesktopAutostart(
        executablePath: '/Applications/Niko & Co.app/Contents/MacOS/Niko',
        environment: {'HOME': tmp.path},
        isWindows: false,
        isLinux: false,
        isMacOS: true,
      );

      expect(await autostart.isEnabled(), isFalse);
      await autostart.setEnabled(true);
      expect(await autostart.isEnabled(), isTrue);

      final plist = autostart.macosLaunchAgentFile!;
      expect(plist.existsSync(), isTrue);
      final content = plist.readAsStringSync();
      expect(content, contains('<string>io.niko.desktop</string>'));
      expect(content, contains('/Applications/Niko &amp; Co.app/Contents/MacOS/Niko'));
      expect(content, contains('<key>RunAtLoad</key>'));

      await autostart.setEnabled(false);
      expect(await autostart.isEnabled(), isFalse);
      expect(plist.existsSync(), isFalse);
    });
  });
}
