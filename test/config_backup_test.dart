import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/daemon/daemon.dart';
import 'package:niko_desktop/l10n/strings.dart';
import 'package:niko_desktop/platform/config_backup.dart';
import 'package:niko_desktop/settings/setting_values.dart';
import 'package:niko_desktop/settings/settings_screen.dart';
import 'package:niko_desktop/state/window_settings.dart';
import 'package:niko_desktop/theme/niko_theme.dart';

import 'fonts.dart';
import 'main_screen_test.dart' show MemoryDaemon;

void main() {
  setUpAll(loadFonts);

  test('buildDesktopBackup and importDesktopBackupJson round-trip groups, profiles, rules, and settings', () async {
    final source = MemoryDaemon()
      ..groupRows = [
        const GroupRow(id: 1, name: '', ungrouped: true, profiles: 1),
        const GroupRow(id: 2, name: 'Work', profiles: 1),
        const GroupRow(id: 3, name: 'RayNode', profiles: 1, nodeId: 'node-secret'),
      ]
      ..profileRows = [
        const ProfileRow(id: 10, groupId: 1, order: 1, type: 'socks', name: 'HomeSocks', address: '198.51.100.1:1080'),
        const ProfileRow(id: 11, groupId: 2, order: 1, type: 'vmess', name: 'WorkVless', address: '198.51.100.2:443'),
        const ProfileRow(id: 12, groupId: 3, order: 1, type: 'vmess', name: 'NodeSecret', address: '203.0.113.7:443'),
      ]
      ..profileBeans.addAll({
        10: '{"name":"HomeSocks","server":"198.51.100.1","server_port":1080}',
        11: '{"name":"WorkVless","server":"198.51.100.2","server_port":443}',
        12: '{"name":"NodeSecret","server":"203.0.113.7","server_port":443}',
      })
      ..ruleRows = [
        const RuleRow(id: 1, name: 'Direct LAN', enabled: true, domains: 'corp.local', outbound: RuleOutbound.direct),
      ]
      ..settingValues['mtu'] = 1400;

    final srcWin = WindowSettings.memory()
      ..advanced = true
      ..theme = 'light'
      ..language = 'en';

    final tmp = await Directory.systemTemp.createTemp('niko-backup-test-');
    addTearDown(() => tmp.delete(recursive: true));

    final summary = await exportDesktopBackup(
      daemon: source,
      destDir: tmp,
      windowSettings: srcWin,
      now: DateTime.utc(2026, 11, 27, 13, 0, 0),
    );
    expect(summary.groups, 1);
    expect(summary.profiles, 2);
    expect(summary.rules, 1);
    expect(summary.skippedNodes, 1);
    final raw = await File(summary.path).readAsString();
    expect(raw, isNot(contains('node-secret')));
    expect(raw, isNot(contains('NodeSecret')));

    final target = MemoryDaemon()
      ..groupRows = [const GroupRow(id: 1, name: '', ungrouped: true, profiles: 0)]
      ..profileRows = []
      ..ruleRows = [];
    final dstWin = WindowSettings.memory();

    final imported = await importDesktopBackupJson(
      daemon: target,
      jsonText: raw,
      windowSettings: dstWin,
    );
    expect(imported.groups, 1);
    expect(imported.profiles, 2);
    expect(imported.rules, 1);
    expect(imported.settingsRestored, isTrue);
    expect(target.groupRows.any((g) => g.name == 'Work'), isTrue);
    expect(target.profileRows, hasLength(2));
    expect(target.ruleRows, hasLength(1));
    expect(target.settingValues['mtu'], 1400);
    expect(dstWin.advanced, isTrue);
    expect(dstWin.theme, 'light');
    expect(dstWin.language, 'en');

    // Re-importing the exact same backup must not duplicate rules or basic groups.
    final reimported = await importDesktopBackupJson(daemon: target, jsonText: raw);
    expect(reimported.groups, 0);
    expect(reimported.rules, 0);
  });

  test('importDesktopBackupJson rejects unknown format or version', () async {
    final target = MemoryDaemon();
    await expectLater(
      importDesktopBackupJson(daemon: target, jsonText: jsonEncode({'format': 'other', 'version': 1})),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      importDesktopBackupJson(daemon: target, jsonText: jsonEncode({'format': desktopBackupFormat, 'version': 99})),
      throwsA(isA<FormatException>()),
    );
  });

  testWidgets('SettingsScreen exposes backup Export and Import buttons', (tester) async {
    var exported = false;
    var importedJson = '';
    final tmpPath = await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('niko-backup-ui-');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/backup.json');
      await f.writeAsString('{"format":"niko-desktop-backup","version":1}');
      return f.path;
    });

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Localizations(
          locale: const Locale('ru'),
          delegates: const [DefaultWidgetsLocalizations.delegate],
          child: NikoTheme(
            colors: NikoColors.dark,
            child: SettingsScreen(
              values: MemorySettingValues(),
              strings: NikoStrings.of(const Locale('ru')),
              onExportBackup: () async {
                exported = true;
                return const BackupExportSummary(
                  path: '/tmp/niko-backup.json',
                  groups: 1,
                  profiles: 3,
                  rules: 2,
                  skippedNodes: 0,
                );
              },
              onImportBackup: (text) async {
                importedJson = text;
                return const BackupImportSummary(groups: 1, profiles: 3, rules: 2, settingsRestored: true);
              },
              pickBackupFile: () async => tmpPath,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Резервная копия конфигурации'), findsOneWidget);
    await tester.ensureVisible(find.text('Экспорт'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Экспорт'));
    await tester.pumpAndSettle();
    expect(exported, isTrue);
    expect(find.textContaining('/tmp/niko-backup.json'), findsOneWidget);

    await tester.ensureVisible(find.text('Импорт'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Импорт'));
    await tester.pumpAndSettle();
    expect(importedJson, contains('niko-desktop-backup'));
    expect(find.textContaining('Импортировано:'), findsOneWidget);
  });
}
