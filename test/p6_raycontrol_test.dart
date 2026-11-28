import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/app.dart';
import 'package:niko_desktop/daemon/daemon.dart';
import 'package:niko_desktop/state/connection_controller.dart';
import 'package:niko_desktop/state/window_settings.dart';

import 'fonts.dart';
import 'main_screen_test.dart' show MemoryDaemon;

void main() {
  setUpAll(loadFonts);

  Future<(MemoryDaemon, ConnectionController, Directory)> pumpNodeShell(
    WidgetTester tester, {
    bool switched = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tmp = Directory.systemTemp.createTempSync('niko-p6-test-');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    final daemon = MemoryDaemon()
      ..api = 15
      ..groupRows = [
        const GroupRow(id: 1, name: '', ungrouped: true),
        const GroupRow(id: 2, name: 'HomeNode', profiles: 2, nodeId: 'n1'),
      ]
      ..profileRows = [
        const ProfileRow(id: 21, groupId: 2, order: 1, type: 'hysteria', name: 'Hy2', address: '203.0.113.10:443'),
        const ProfileRow(id: 22, groupId: 2, order: 2, type: 'hysteria', name: 'Hy2 · eu', address: '198.51.100.77:443'),
      ]
      ..selectedId = 22
      ..nodeRows = [
        NodeRow(
          id: 'n1',
          host: '203.0.113.10',
          name: 'HomeNode',
          groupId: 2,
          profiles: 2,
          subscription: true,
          updated: 1790000000,
          admin: true,
          hasProbe: true,
          hasLan: true,
          lanShow: false,
          relays: 1,
          switchedFrom: switched ? 'Hy2' : '',
          switchedTo: switched ? 'Hy2 · eu' : '',
          switchedAt: switched ? 1790000100 : 0,
        ),
      ];
    final controller = ConnectionController(daemon: daemon, loadConfig: null)..attach();
    final settings = WindowSettings.memory(advanced: true, language: 'en');
    addTearDown(() {
      controller.dispose();
      settings.dispose();
    });

    await tester.pumpWidget(
      NikoApp(
        controller: controller,
        settings: settings,
        locale: const Locale('en'),
        saveTo: () => tmp,
      ),
    );
    await tester.pumpAndSettle();
    return (daemon, controller, tmp);
  }

  testWidgets('D-STATE-SWITCHED banner appears on MainScreen and dismiss clears it', (tester) async {
    final (daemon, _, _) = await pumpNodeShell(tester, switched: true);
    expect(find.text('Profile switched automatically'), findsOneWidget);
    expect(find.textContaining('Hy2 · eu'), findsWidgets);

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(daemon.clearedSwitchedNodes, ['n1']);
    expect(find.text('Profile switched automatically'), findsNothing);
  });

  testWidgets('D-WHY diagnostic screen runs node test, displays findings, and saves redacted report', (tester) async {
    final (_, _, tmp) = await pumpNodeShell(tester);
    await tester.tap(find.text('Nodes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HomeNode'));
    await tester.pumpAndSettle();

    expect(find.text('Relays: 1'), findsOneWidget);
    expect(find.text('Why isn’t it working?'), findsOneWidget);

    await tester.tap(find.text('Why isn’t it working?'));
    await tester.pumpAndSettle();
    expect(find.text('Node diagnostics · HomeNode'), findsOneWidget);

    await tester.tap(find.text('Start diagnostics'));
    await tester.pumpAndSettle();

    expect(find.text('Only relay profiles work on this network'), findsOneWidget);
    expect(find.text('Hy2 · eu'), findsOneWidget);
    expect(find.text('timed out'), findsOneWidget);

    await tester.tap(find.text('Save report'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    final saved = tmp.listSync().whereType<File>().where((f) => f.path.endsWith('.log')).toList();
    expect(saved, hasLength(1));
    expect(saved.single.readAsStringSync(), contains('redacted report'));
  });

  testWidgets('D-ADMIN panel loads status, users/devices, creates invite, revokes device, services & audit', (tester) async {
    final (daemon, _, _) = await pumpNodeShell(tester);
    final adminCalls = <(String, String)>[];
    daemon.onNodeAdminCall = (nodeId, method, body) async {
      adminCalls.add((method, body));
      return switch (method) {
        'GetStatus' => '{"version":"0.36.0","host":"node-1.example","uptimeSeconds":3600,"warnings":["Check Brutal"]}',
        'ListUsers' => '{"users":[{"name":"alice","trafficUsed":1048576,"trafficLimit":1073741824}]}',
        'ListDevices' => '{"devices":[{"id":"dev1","name":"Laptop","role":"user"}]}',
        'CreateInvite' => '{"inviteCodeShort":"rcinv2:generated-token","pin":"482910"}',
        'RevokeDevice' => '{"user":"alice","device":"Laptop","credentials":1}',
        'ListServices' => '{"services":[{"name":"hy2","kind":"hysteria2","port":443,"enabled":true}]}',
        'SetServiceEnabled' => '{}',
        'ListAudit' => '{"entries":[{"action":"create_invite","target":"alice","actor":"admin","result":"ok"}]}',
        _ => '{}',
      };
    };

    await tester.tap(find.text('Nodes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HomeNode'));
    await tester.pumpAndSettle();

    // Toggle LAN visibility on node card
    await tester.tap(find.text('Show this device on node LAN'));
    await tester.pumpAndSettle();
    expect(daemon.lanShowToggles, [('n1', true)]);

    // Open Admin panel
    await tester.tap(find.text('Admin panel'));
    await tester.pumpAndSettle();
    expect(find.text('0.36.0'), findsOneWidget);
    expect(find.text('node-1.example'), findsOneWidget);
    expect(find.text('Check Brutal'), findsOneWidget);

    // Users tab: select alice, create invite with PIN toggle, revoke Laptop
    await tester.tap(find.text('Users'));
    await tester.pumpAndSettle();
    expect(find.text('alice'), findsOneWidget);

    await tester.tap(find.text('alice'));
    await tester.pumpAndSettle();
    expect(find.text('Laptop'), findsOneWidget);

    await tester.tap(find.text('Create invite'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Protect invite with PIN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('rcinv2:generated-token'), findsOneWidget);
    expect(find.textContaining('PIN: 482910'), findsOneWidget);
    expect(
      adminCalls.any((c) => c.$1 == 'CreateInvite' && c.$2.contains('"pin":true') && c.$2.contains('"ttlSeconds":"86400"')),
      isTrue,
    );

    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke device “Laptop”?'), findsOneWidget);
    await tester.tap(find.text('Revoke').first);
    await tester.pumpAndSettle();
    expect(adminCalls.any((c) => c.$1 == 'RevokeDevice' && c.$2 == '{"id":"dev1"}'), isTrue);

    // Services & Audit tabs
    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();
    expect(find.text('hy2'), findsOneWidget);
    await tester.tap(find.text('Disable'));
    await tester.pumpAndSettle();
    expect(adminCalls.any((c) => c.$1 == 'SetServiceEnabled' && c.$2.contains('"enabled":false')), isTrue);

    await tester.tap(find.text('Audit'));
    await tester.pumpAndSettle();
    expect(find.text('create_invite alice'), findsOneWidget);
    expect(adminCalls.any((c) => c.$1 == 'ListAudit'), isTrue);
  });

  testWidgets('SettingsScreen toggles raycontrolAutoSwitch, raycontrolBrutal, and raycontrolReports', (tester) async {
    final (daemon, _, _) = await pumpNodeShell(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Measured Hysteria2 Brutal'));
    await tester.tap(find.text('Measured Hysteria2 Brutal'));
    await tester.pumpAndSettle();
    expect(daemon.settingValues['raycontrolBrutal'], isTrue);

    await tester.ensureVisible(find.text('Summary for admin'));
    await tester.tap(find.text('Summary for admin'));
    await tester.pumpAndSettle();
    expect(daemon.settingValues['raycontrolReports'], isTrue);
  });
}
