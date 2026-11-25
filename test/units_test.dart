import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/app.dart';
import 'package:niko_desktop/daemon/daemon.dart';
import 'package:niko_desktop/daemon/endpoint.dart';
import 'package:niko_desktop/platform/places.dart';
import 'package:niko_desktop/state/connection_controller.dart';
import 'package:niko_desktop/state/window_settings.dart';
import 'package:niko_desktop/ui/format.dart';
import 'package:niko_desktop/ui/icons.dart';

/// The box of the line itself: Path.getBounds takes an arc's control points, which lie outside it.
Rect drawnBounds(Path path) {
  var left = double.infinity, top = double.infinity, right = -double.infinity, bottom = -double.infinity;
  for (final metric in path.computeMetrics()) {
    for (var at = 0.0; at <= metric.length; at += 0.02) {
      final point = metric.getTangentForOffset(at)!.position;
      left = point.dx < left ? point.dx : left;
      top = point.dy < top ? point.dy : top;
      right = point.dx > right ? point.dx : right;
      bottom = point.dy > bottom ? point.dy : bottom;
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

void main() {
  group('the development endpoint', () {
    test('is 127.0.0.1 and a port', () {
      expect(DevEndpoint.parse('127.0.0.1:18080')?.port, 18080);
      expect(DevEndpoint.parse('127.0.0.1:18080').toString(), '127.0.0.1:18080');
    });
    test('is nothing else', () {
      for (final text in [
        '0.0.0.0:18080', ':18080', 'localhost:18080', '127.0.0.2:18080', '[::1]:18080', '192.168.1.5:18080',
        '127.0.0.1', '127.0.0.1:', '127.0.0.1:80', '127.0.0.1:1023', '127.0.0.1:65536', '127.0.0.1:018080',
        '127.0.0.1:18080 ', ' 127.0.0.1:18080', '127.0.0.1:18080/x', 'example.com:443', '',
        '127.0.0.1:18080\n', '127.0.0.1:18080\n0.0.0.0:1', '127.0.0.1:18080@evil.example',
      ]) {
        expect(DevEndpoint.parse(text), isNull, reason: '"$text"');
      }
    });
  });

  group('technical values', () {
    test('rates as the core writes them', () {
      expect(formatRate(0), '0 B/s');
      expect(formatRate(999), '999 B/s');
      expect(formatRate(312 * 1024), '312 KB/s');
      expect(formatRate((4.2 * 1024 * 1024).round()), '4.2 MB/s');
      expect(formatRate(42 * 1024 * 1024), '42 MB/s');
      expect(formatBytes(38 * 1024 * 1024 * 1024), '38 GB');
      expect(formatBytes(-5), '0 B');
    });
    test('the time since the start', () {
      expect(formatElapsed(Duration.zero), '00:00:00');
      expect(formatElapsed(const Duration(minutes: 42, seconds: 17)), '00:42:17');
      expect(formatElapsed(const Duration(hours: 101, minutes: 2, seconds: 3)), '101:02:03');
      expect(formatElapsed(const Duration(seconds: -4)), '00:00:00');
    });
  });

  group('icons', () {
    test('every icon is path data this reads, inside the 24 grid', () {
      for (final data in NikoIcons.all) {
        final bounds = drawnBounds(parseSvgPath(data));
        expect(bounds.left >= 0 && bounds.top >= 0 && bounds.right <= 24 && bounds.bottom <= 24, isTrue,
            reason: '$data: $bounds');
        expect(bounds.width > 8 || bounds.height > 8, isTrue, reason: data);
      }
    });
    test('the power icon: a stem and an open arc around it', () {
      final bounds = drawnBounds(parseSvgPath(NikoIcons.power));
      // the arc of radius 9 about (12, 13): from 3 to 21 across, down to 22
      expect(bounds.left, closeTo(3, 0.05));
      expect(bounds.right, closeTo(21, 0.05));
      expect(bounds.top, closeTo(2, 0.05));
      expect(bounds.bottom, closeTo(22, 0.05));
    });
    test('arc flags written together, and a command this does not know', () {
      expect(drawnBounds(parseSvgPath('M2 12a10 10 0 1020 0')).right, closeTo(22, 0.05));
      expect(() => parseSvgPath('M0 0q1 1 2 2'), throwsFormatException);
      expect(() => parseSvgPath('1 2 3'), throwsFormatException);
    });
  });
  group('what the connections screen writes', () {
    test('the age', () {
      expect(formatAge(const Duration(seconds: 12)), '12 s');
      expect(formatAge(const Duration(minutes: 4, seconds: 59)), '4 min');
      expect(formatAge(const Duration(hours: 2, minutes: 10)), '2 h');
      expect(formatAge(const Duration(seconds: -3)), '0 s');
    });

    test('the target by name where there is one', () {
      expect(connectionTarget('93.184.216.34:443', 'www.example.com'), 'www.example.com:443');
      expect(connectionTarget('93.184.216.34:443', ''), '93.184.216.34:443');
      expect(connectionTarget('[2001:db8::1]:443', 'v6.example.com'), 'v6.example.com:443');
    });

    test('a program by its file', () {
      expect(processName(r'C:\Program Files\Browser\browser.exe'), 'browser');
      expect(processName('/usr/bin/curl'), 'curl');
      expect(processName('ssh'), 'ssh');
    });

    test('a log line without the terminal colours', () {
      expect(plainLogText('\x1b[36mINFO\x1b[0m[0000] started'), 'INFO[0000] started');
      expect(plainLogText('plain'), 'plain');
    });
  });

  group('places on the disk', () {
    test('the settings file, as each system names a user\'s folder', () {
      expect(settingsFile({'APPDATA': r'C:\Users\a\AppData\Roaming'}, 'windows')!.path,
          r'C:\Users\a\AppData\Roaming\Niko\window.json');
      expect(settingsFile({'HOME': '/home/a'}, 'linux')!.path, '/home/a/.config/niko/window.json');
      expect(settingsFile({'HOME': '/home/a', 'XDG_CONFIG_HOME': '/cfg'}, 'linux')!.path, '/cfg/niko/window.json');
      expect(settingsFile({'HOME': '/Users/a'}, 'macos')!.path, '/Users/a/Library/Application Support/Niko/window.json');
      // no home: nothing kept, not a file in the working folder
      expect(settingsFile({}, 'linux'), isNull);
      expect(settingsFile({'APPDATA': ''}, 'windows'), isNull);
    });

    test('xdg user-dirs.dirs parsing', () {
      const sample = '''
# Created by xdg-user-dirs-update
XDG_DESKTOP_DIR="\$HOME/Рабочий стол"
XDG_DOWNLOAD_DIR="\$HOME/Загрузки"
# XDG_DOWNLOAD_DIR="\$HOME/Ignored"
''';
      expect(xdgUserDir(sample, '/home/a', 'XDG_DOWNLOAD_DIR'), '/home/a/Загрузки');
      expect(xdgUserDir(sample, '/home/a/', 'XDG_DOWNLOAD_DIR'), '/home/a/Загрузки');
      expect(xdgUserDir('XDG_DOWNLOAD_DIR="/mnt/data/dl"\r\n', '/home/a', 'XDG_DOWNLOAD_DIR'), '/mnt/data/dl');
      // disabled directory per xdg-user-dirs specification
      expect(xdgUserDir('XDG_DOWNLOAD_DIR="\$HOME"\n', '/home/a', 'XDG_DOWNLOAD_DIR'), isNull);
      expect(xdgUserDir('XDG_DOWNLOAD_DIR="\$HOME/"\n', '/home/a', 'XDG_DOWNLOAD_DIR'), isNull);
      // relative, unquoted, unknown variable, or malformed lines are ignored
      expect(xdgUserDir('XDG_DOWNLOAD_DIR="Downloads"\n', '/home/a', 'XDG_DOWNLOAD_DIR'), isNull);
      expect(xdgUserDir('XDG_DOWNLOAD_DIR=\$HOME/Downloads\n', '/home/a', 'XDG_DOWNLOAD_DIR'), isNull);
      expect(xdgUserDir('XDG_DOWNLOAD_DIR="\$OTHER/Downloads"\n', '/home/a', 'XDG_DOWNLOAD_DIR'), isNull);
      expect(xdgUserDir('XDG_DOWNLOAD_DIR="\$HOME2/Downloads"\n', '/home/a', 'XDG_DOWNLOAD_DIR'), isNull);
      expect(xdgUserDir('not even an assignment\n', '/home/a', 'XDG_DOWNLOAD_DIR'), isNull);
      // malformed line after a valid one is skipped rather than clearing it
      expect(
        xdgUserDir('XDG_DOWNLOAD_DIR="\$HOME/Загрузки"\nXDG_DOWNLOAD_DIR=relative\n', '/home/a', 'XDG_DOWNLOAD_DIR'),
        '/home/a/Загрузки',
      );
      // last valid line wins, including disabling an earlier value
      expect(
        xdgUserDir('XDG_DOWNLOAD_DIR="\$HOME/First"\nXDG_DOWNLOAD_DIR="\$HOME"\n', '/home/a', 'XDG_DOWNLOAD_DIR'),
        isNull,
      );
    });

    test('the folder a file is saved into: XDG env, user-dirs.dirs, Downloads, else home', () async {
      final home = await Directory.systemTemp.createTemp('niko-home-');
      addTearDown(() => home.delete(recursive: true));
      expect(saveDirectory({'HOME': home.path}, 'linux')!.path, home.path);

      final dl = await Directory('${home.path}/Downloads').create();
      expect(saveDirectory({'HOME': home.path}, 'linux')!.path, dl.path);

      // user-dirs.dirs beats ~/Downloads
      final localized = await Directory('${home.path}/Загрузки').create();
      final cfg = await Directory('${home.path}/.config').create();
      await File('${cfg.path}/user-dirs.dirs').writeAsString('XDG_DOWNLOAD_DIR="\$HOME/Загрузки"\n');
      expect(saveDirectory({'HOME': home.path}, 'linux')!.path, localized.path);

      // XDG_CONFIG_HOME overrides ~/.config
      final altCfg = await Directory('${home.path}/altcfg').create();
      final custom = await Directory('${home.path}/CustomDL').create();
      await File('${altCfg.path}/user-dirs.dirs').writeAsString('XDG_DOWNLOAD_DIR="${custom.path}"\n');
      expect(
        saveDirectory({'HOME': home.path, 'XDG_CONFIG_HOME': altCfg.path}, 'linux')!.path,
        custom.path,
      );

      // explicit XDG_DOWNLOAD_DIR env var has top precedence
      final envDir = await Directory('${home.path}/EnvDL').create();
      expect(
        saveDirectory({'HOME': home.path, 'XDG_DOWNLOAD_DIR': envDir.path}, 'linux')!.path,
        envDir.path,
      );

      // relative XDG_CONFIG_HOME / XDG_DOWNLOAD_DIR are ignored per XDG spec
      expect(
        saveDirectory({'HOME': home.path, 'XDG_CONFIG_HOME': 'relative/cfg', 'XDG_DOWNLOAD_DIR': 'relative/dl'}, 'linux')!
            .path,
        localized.path,
      );

      expect(saveDirectory({'HOME': '/nowhere/at/all'}, 'linux'), isNull);
    });

    test('a name from the daemon is a file name, never a path', () {
      expect(safeFileName('crash-1.zip'), 'crash-1.zip');
      expect(safeFileName('../../etc/passwd'), 'passwd');
      expect(safeFileName(r'..\..\Windows\win.ini'), 'win.ini');
      expect(safeFileName('.hidden'), 'hidden');
      expect(safeFileName('a b:c?.zip'), 'a_b_c_.zip');
      expect(safeFileName('..'), 'niko');
    });

    test('a save never replaces a file', () async {
      final folder = await Directory.systemTemp.createTemp('niko-save-');
      addTearDown(() => folder.delete(recursive: true));
      final first = await saveNew(folder, 'log.txt', [1]);
      final second = await saveNew(folder, 'log.txt', [2]);
      final third = await saveNew(folder, '../log.txt', [3]);
      expect([first, second, third].map((f) => f.uri.pathSegments.last), ['log.txt', 'log (2).txt', 'log (3).txt']);
      expect(first.readAsBytesSync(), [1]);
      expect(third.parent.path, folder.path);
    });
  });

  group('the window\'s settings', () {
    test('the view is kept and read back; a missing or broken file gives the defaults', () async {
      final folder = await Directory.systemTemp.createTemp('niko-settings-');
      addTearDown(() => folder.delete(recursive: true));
      final file = File('${folder.path}/niko/window.json');
      final first = await WindowSettings.load(file);
      expect(first.advanced, isFalse);
      first.advanced = true;
      await first.save();
      expect((await WindowSettings.load(file)).advanced, isTrue);
      expect(File('${file.path}.new').existsSync(), isFalse);
      file.writeAsStringSync('{not json');
      expect((await WindowSettings.load(file)).advanced, isFalse);
      // saves asked for at once run one after another: the last choice is what stays
      final quick = await WindowSettings.load(file);
      final saves = <Future<void>>[];
      for (final advanced in [true, false, true, false, true]) {
        quick.advanced = advanced;
        saves.add(quick.save());
      }
      await Future.wait(saves);
      expect((await WindowSettings.load(file)).advanced, isTrue);
      expect(File('${file.path}.new').existsSync(), isFalse);
      // kept nowhere: nothing written, nothing thrown
      final memory = WindowSettings.memory(advanced: true);
      await memory.save();
      expect(memory.advanced, isTrue);
    });

    test('theme, language, unknown values, and unknown keys are handled cleanly', () async {
      final folder = await Directory.systemTemp.createTemp('niko-settings-ext-');
      addTearDown(() => folder.delete(recursive: true));
      final file = File('${folder.path}/window.json');
      await file.writeAsString(jsonEncode({
        'view': 'simple',
        'theme': 'sepia',
        'language': 'de',
        'recentChecks': [
          {'target': 'example.com', 'network': 'tcp'},
        ],
        'futureFlag': 42,
      }));

      final loaded = await WindowSettings.load(file);
      expect(loaded.theme, 'system');
      expect(loaded.language, 'system');

      var notifications = 0;
      loaded.addListener(() => notifications++);
      loaded.theme = 'dark';
      loaded.theme = 'dark'; // no-op
      loaded.language = 'en';
      expect(notifications, 2);
      await loaded.save();

      final saved = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      expect(saved['theme'], 'dark');
      expect(saved['language'], 'en');
      expect(saved['futureFlag'], 42);
      expect(saved['recentChecks'], [
        {'target': 'example.com', 'network': 'tcp'},
      ]);

      final reloaded = await WindowSettings.load(file);
      expect((reloaded.theme, reloaded.language), ('dark', 'en'));
    });
  });

  group('window close lifecycle', () {
    testWidgets('System.requestAppExit waits for queued settings writes to flush', (tester) async {
      final saveGate = Completer<void>();
      final settings = _DelayedSaveSettings(saveGate);
      final controller = ConnectionController(daemon: null, loadConfig: null);
      addTearDown(controller.dispose);

      await tester.pumpWidget(NikoApp(controller: controller, settings: settings, locale: const Locale('en')));

      Object? reply;
      final call = SystemChannels.platform.codec.encodeMethodCall(
        const MethodCall('System.requestAppExit', <String, dynamic>{'type': 'cancelable'}),
      );
      final handled = tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.platform.name,
        call,
        (data) => reply = data == null ? null : SystemChannels.platform.codec.decodeEnvelope(data),
      );

      await tester.pump();
      expect(settings.flushCalls, 1);
      expect(reply, isNull);

      saveGate.complete();
      await handled;
      await tester.pump();
      expect(reply, {'response': 'exit'});
    });

    testWidgets('System.requestAppExit still exits after 1s if flushing stalls', (tester) async {
      final stalled = Completer<void>();
      final settings = _DelayedSaveSettings(stalled);
      final controller = ConnectionController(daemon: null, loadConfig: null);
      addTearDown(controller.dispose);

      await tester.pumpWidget(NikoApp(controller: controller, settings: settings, locale: const Locale('en')));

      Object? reply;
      final call = SystemChannels.platform.codec.encodeMethodCall(
        const MethodCall('System.requestAppExit', <String, dynamic>{'type': 'cancelable'}),
      );
      final handled = tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.platform.name,
        call,
        (data) => reply = data == null ? null : SystemChannels.platform.codec.decodeEnvelope(data),
      );

      await tester.pump();
      expect(reply, isNull);
      await tester.pump(const Duration(seconds: 1));
      await handled;
      expect(reply, {'response': 'exit'});
    });
  });
}

class _DelayedSaveSettings extends ChangeNotifier implements WindowSettings {
  _DelayedSaveSettings(this._gate);

  final Completer<void> _gate;
  int flushCalls = 0;

  @override
  bool advanced = false;

  @override
  String theme = 'system';

  @override
  String language = 'system';

  @override
  Future<void> flush() {
    flushCalls++;
    return _gate.future;
  }

  @override
  Future<void> save() => _gate.future;
}
