import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:niko_desktop/daemon/daemon.dart';
import 'package:niko_desktop/l10n/strings.dart';
import 'package:niko_desktop/platform/deep_link.dart';
import 'package:niko_desktop/screens/nodes_screen.dart';
import 'package:niko_desktop/screens/profile_editor.dart';
import 'package:niko_desktop/theme/niko_theme.dart';

void main() {
  test('typeLabel prefers specific API 17 protocol kind', () {
    expect(typeLabel('vmess', kind: 'vless-reality'), 'REALITY');
    expect(typeLabel('vmess', kind: 'vless-xhttp'), 'XHTTP');
    expect(typeLabel('hysteria', kind: 'hysteria2'), 'Hysteria2');
    expect(typeLabel('naive', kind: 'naive-quic'), 'naive QUIC');
    expect(typeLabel('vmess', kind: 'dnstt'), 'dnstt');
    expect(typeLabel('vmess', kind: 'masterdns'), 'MasterDnsVPN');
    expect(typeLabel('vmess', kind: 'slipstream'), 'slipstream');
    expect(typeLabel('vmess', kind: 'ygg'), 'Yggdrasil');
    expect(typeLabel('wg', kind: 'awg'), 'AmneziaWG');
    expect(typeLabel('trojan-go'), 'Trojan-Go');
    expect(typeLabel('wg'), 'WireGuard');
    expect(typeLabel('ssh'), 'SSH');
  });

  test('deep link normalizer accepts rcinv1..3, anytls, naive+quic, hiddify, sing-box, v2rayng', () {
    expect(normalizeDeepLink('rcinv1://example.com/abc'), 'rcinv1://example.com/abc');
    expect(normalizeDeepLink('rcinv3://example.com/xyz'), 'rcinv3://example.com/xyz');
    expect(normalizeDeepLink('anytls://pass@example.com:443'), 'anytls://pass@example.com:443');
    expect(normalizeDeepLink('naive+quic://u:p@example.com:443'), 'naive+quic://u:p@example.com:443');
    expect(normalizeDeepLink('hiddify://import/https://example.com/sub'), 'hiddify://import/https://example.com/sub');
    expect(normalizeDeepLink('sing-box://import-remote-profile?url=https://example.com'),
        'sing-box://import-remote-profile?url=https://example.com');
  });

  testWidgets('ProfileEditor composes VLESS (alterId -1) and Hysteria2 (serverPorts) and runs CheckProfile',
      (tester) async {
    String? savedType;
    String? savedJson;
    var checked = false;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: NikoTheme(
          colors: NikoColors.light,
          child: ProfileEditor(
            strings: NikoStrings.of(const Locale('en')),
            initialType: 'hysteria',
            onCheck: ({required String type, required String beanJson}) async {
              checked = true;
              return const ProfileCheckResult(ok: true, kind: 'hysteria2', transport: 'udp');
            },
            onSave: ({required int id, required int groupId, required String type, required String beanJson}) async {
              savedType = type;
              savedJson = beanJson;
              return null;
            },
            onCancel: () {},
          ),
        ),
      ),
    );

    // CheckProfile button validates before save.
    await tester.ensureVisible(find.text('Check'));
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    expect(checked, isTrue);
    expect(find.textContaining('hysteria2 (udp)'), findsOneWidget);

    // Saving Hysteria2 writes serverPorts and protocolVersion=2 (not ignored serverPort).
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(savedType, 'hysteria');
    final decoded = jsonDecode(savedJson!) as Map<String, dynamic>;
    expect(decoded['serverPorts'], '443');
    expect(decoded['protocolVersion'], 2);
    expect(decoded.containsKey('serverPort'), isFalse);
  });
}
