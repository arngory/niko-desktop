import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/daemon/daemon.dart';
import 'package:niko_desktop/screens/add_screen.dart';
import 'package:niko_desktop/screens/nodes_screen.dart';
import 'package:niko_desktop/state/connection_controller.dart';
import 'package:niko_desktop/state/profiles_feed.dart';
import 'package:niko_desktop/theme/niko_theme.dart';
import 'package:niko_desktop/ui/qr_code.dart';

import 'fonts.dart';
import 'main_screen_test.dart' show MemoryDaemon;

Widget _wrap(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: Localizations(
        locale: const Locale('ru'),
        delegates: const [DefaultWidgetsLocalizations.delegate],
        child: NikoTheme(
          colors: NikoColors.dark,
          child: ColoredBox(color: NikoColors.dark.surface0, child: child),
        ),
      ),
    );

void main() {
  setUpAll(loadFonts);

  test('QR encode and decode round-trip handles profile, subscription, and invite URIs', () {
    const samples = [
      'vless://11111111-2222-3333-4444-555555555555@example.com:443?security=reality#Frankfurt',
      'https://sub.example.com/api/v1/client/subscribe?token=abc123',
      'rcinv1:eyJob3N0IjoiZXhhbXBsZS5jb20iLCJwb3J0Ijo0NDN9',
    ];
    for (final sample in samples) {
      final rendered = renderQrToRgba(sample, modulePx: 6, quietModules: 4);
      expect(rendered, isNotNull, reason: 'failed to encode $sample');
      final decoded = decodeQrFromRgba(rendered!.rgba, rendered.width, rendered.height);
      expect(decoded, sample);

      // Inverted (white-on-black) QR screenshot should also decode.
      final inverted = Uint8List.fromList(rendered.rgba);
      for (var i = 0; i < inverted.length; i += 4) {
        inverted[i] = 255 - inverted[i];
        inverted[i + 1] = 255 - inverted[i + 1];
        inverted[i + 2] = 255 - inverted[i + 2];
      }
      expect(decodeQrFromRgba(inverted, rendered.width, rendered.height), sample);
    }
  });

  test('encodeQrImage rejects empty and over-capacity payloads cleanly', () {
    expect(encodeQrImage(''), isNull);
    expect(encodeQrImage('a' * 5000), isNull);
  });

  testWidgets('AddScreen imports link decoded from QR image file', (tester) async {
    final qrPath = await tester.runAsync(() async {
      final tmp = await Directory.systemTemp.createTemp('niko-qr-test-');
      addTearDown(() => tmp.delete(recursive: true));
      final qrFile = File('${tmp.path}/sample.png');
      await qrFile.writeAsBytes(const [1, 2, 3, 4]);
      return qrFile.path;
    });

    final daemon = MemoryDaemon();
    final ctrl = ConnectionController(daemon: daemon, loadConfig: null)..attach();
    final feed = ProfilesFeed(ctrl)..show();
    addTearDown(() {
      feed.dispose();
      ctrl.dispose();
    });
    await tester.pump();

    var addedCount = 0;
    await tester.pumpWidget(
      _wrap(
        AddScreen(
          feed: feed,
          pickQrFile: () async => qrPath,
          decodeQrBytes: (_) async => 'rcinv1:eyJob3N0IjoiMjAzLjAuMTEzLjcifQ',
          onDone: (n) => addedCount = n,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Из QR'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(find.text('Приглашение узла'), findsOneWidget);
    expect(addedCount, 0);
  });

  testWidgets('NodesScreen opens QR modal for shareable profile and hides QR for node group', (tester) async {
    final daemon = MemoryDaemon()
      ..groupRows = const [
        GroupRow(id: 1, name: '', ungrouped: true, profiles: 1),
        GroupRow(id: 2, name: 'NodeGroup', profiles: 1, nodeId: 'n1'),
      ]
      ..profileRows = [
        const ProfileRow(id: 10, groupId: 1, order: 1, type: 'socks', name: 'MySocks', address: '198.51.100.1:1080'),
        const ProfileRow(id: 20, groupId: 2, order: 1, type: 'vmess', name: 'NodeRow', address: '203.0.113.7:443'),
      ];
    final ctrl = ConnectionController(daemon: daemon, loadConfig: null)..attach();
    final feed = ProfilesFeed(ctrl)..show();
    addTearDown(() {
      feed.dispose();
      ctrl.dispose();
    });

    await tester.pumpWidget(
      _wrap(
        ListenableBuilder(
          listenable: feed,
          builder: (_, _) => NodesScreen(
            feed: feed,
            linked: true,
            onAdd: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('QR'), findsOneWidget);
    await tester.tap(find.text('QR'));
    await tester.pumpAndSettle();

    expect(find.byType(NikoQrDialog), findsOneWidget);
    expect(find.byType(NikoQrView), findsOneWidget);
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.byType(NikoQrDialog), findsNothing);

    // Switch to raycontrol node group: QR share button must be hidden (salamander-device-v1 §6).
    await tester.tap(find.text('NodeGroup'));
    await tester.pumpAndSettle();
    expect(find.text('QR'), findsNothing);
  });
}
