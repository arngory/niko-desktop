import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart' show GrpcError;
import 'package:niko_desktop/app.dart';
import 'package:niko_desktop/daemon/daemon.dart';
import 'package:niko_desktop/platform/deep_link.dart';
import 'package:niko_desktop/platform/desktop_integration.dart';
import 'package:niko_desktop/platform/service_install.dart';
import 'package:niko_desktop/state/connection_controller.dart';
import 'package:niko_desktop/state/window_settings.dart';

import 'fonts.dart';
import 'main_screen_test.dart' show MemoryDaemon;

void main() {
  setUpAll(loadFonts);

  group('URL scheme deep-link parser (D-ADD-11)', () {
    test('normalizes --url, niko://, sn://, clash:// and preserves +, &, # in inner links', () {
      expect(
        normalizeDeepLink('niko://import?url=https%3A%2F%2Fexample.com%2Fsub.txt'),
        'https://example.com/sub.txt',
      );
      expect(
        normalizeDeepLink('niko://add?link=vless://uuid@host:443?type=ws&path=/a+b#One'),
        'vless://uuid@host:443?type=ws&path=/a+b#One',
      );
      expect(
        normalizeDeepLink('niko://import?url=javascript%3Aalert(1)'),
        isNull,
      );
      expect(
        normalizeDeepLink('niko://import?url=niko%3A%2F%2Fimport%3Furl%3Dhttps%3A%2F%2Fx'),
        isNull,
      );
      expect(normalizeDeepLink('sn://socks?addr=1.2.3.4'), 'sn://socks?addr=1.2.3.4');
      expect(normalizeDeepLink('clash://install-config?url=https://sub.example'), 'clash://install-config?url=https://sub.example');
      expect(normalizeDeepLink('hysteria2://pass@host:443#Hy2'), 'hysteria2://pass@host:443#Hy2');
      expect(normalizeDeepLink('https://example.com/not-a-scheme'), isNull);
      expect(normalizeDeepLink('javascript:alert(1)'), isNull);
      expect(extractDeepLink(['--url', 'sn://test', '--after-install']), 'sn://test');
      expect(extractDeepLink(['--flag', 'foo', 'sn://test']), 'sn://test');
    });
  });

  Future<(MemoryDaemon, ConnectionController, MethodChannel)> pumpShell(
    WidgetTester tester, {
    int api = 16,
    bool withDaemon = true,
    String? initialImportLink,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final channel = const MethodChannel('niko/window');
    final desktop = DesktopIntegration(channel: channel);
    final daemon = MemoryDaemon()
      ..api = api
      ..groupRows = [const GroupRow(id: 1, name: '', ungrouped: true)];
    final controller = ConnectionController(daemon: withDaemon ? daemon : null, loadConfig: null)..attach();
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
        desktop: desktop,
        saveTo: () => Directory('/tmp/updates'),
        initialImportLink: initialImportLink,
      ),
    );
    await tester.pumpAndSettle();
    return (daemon, controller, channel);
  }

  testWidgets('Deep-link launch opens AddScreen prefilled and running instance receives forwarded links (D-ADD-11)', (
    tester,
  ) async {
    final (_, _, channel) = await pumpShell(tester, initialImportLink: 'vless://abc@example.com:443#DeepLink');
    expect(find.text('vless://abc@example.com:443#DeepLink'), findsOneWidget);

    // Forward a second deep link to the already-running instance via niko/window MethodChannel.
    final codec = const StandardMethodCodec();
    final msg = codec.encodeMethodCall(const MethodCall('deepLink', 'niko://import?url=hysteria2://p@host:443#LiveLink'));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(channel.name, msg, (_) {});
    await tester.pumpAndSettle();
    expect(find.text('hysteria2://p@host:443#LiveLink'), findsOneWidget);
  });

  testWidgets('RulesScreen applies China, Iran, and Ads presets (gated on API >= 16)', (tester) async {
    final (daemon, _, _) = await pumpShell(tester, api: 16);
    await tester.tap(find.text('Rules'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('China preset'));
    await tester.pumpAndSettle();
    expect(daemon.appliedPresets, [RoutePreset.china]);
    expect(find.text('China services: directly'), findsOneWidget);

    await tester.tap(find.text('Iran preset'));
    await tester.pumpAndSettle();
    expect(daemon.appliedPresets, [RoutePreset.china, RoutePreset.iran]);
    expect(find.text('Iranian services: directly'), findsOneWidget);

    await tester.tap(find.text('Block ads'));
    await tester.pumpAndSettle();
    expect(daemon.appliedPresets, [RoutePreset.china, RoutePreset.iran, RoutePreset.ads]);
    expect(find.text('Block ads and trackers'), findsOneWidget);
  });

  testWidgets('SettingsScreen checks/downloads updates, distinguishes unverified mirror, clears stale state, and preserves state across FAQ', (
    tester,
  ) async {
    final (daemon, _, _) = await pumpShell(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    // Unverified mirror update clearly says signature will be verified on download.
    daemon.onCheckUpdate = (_, _) async => const UpdateCheckResult(
          currentVersion: '0.1.0',
          latestVersion: '0.2.0',
          tag: 'v0.2.0',
          updateAvailable: true,
          source: 'mirror',
          verified: false,
        );
    await tester.ensureVisible(find.text('Check for updates'));
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(find.text('Version 0.2.0 available (mirror)'), findsOneWidget);
    expect(find.textContaining('signature will be verified on download'), findsOneWidget);

    // Opening and closing FAQ preserves the update banner (SettingsScreen is not disposed).
    await tester.ensureVisible(find.text('Help & what values mean'));
    await tester.tap(find.text('Help & what values mean'));
    await tester.pumpAndSettle();
    expect(find.text('PROXY VS VPN (TUN) MODE'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Version 0.2.0 available (mirror)'), findsOneWidget);

    // Verified GitHub check + verified download.
    daemon.onCheckUpdate = null;
    await tester.ensureVisible(find.text('Check for updates'));
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(find.text('Version 0.2.0 available (github)'), findsOneWidget);
    expect(find.textContaining('minisign signature verified'), findsOneWidget);

    await tester.ensureVisible(find.text('Download verified update'));
    await tester.tap(find.text('Download verified update'));
    await tester.pumpAndSettle();
    expect(find.textContaining('/tmp/updates/niko-0.2.0-linux-amd64.tar.gz'), findsOneWidget);

    // Tampered signature error clears stale Download button and shows danger banner.
    daemon.onCheckUpdate = (_, _) async => throw const GrpcError.permissionDenied('minisign signature verification failed');
    await tester.ensureVisible(find.text('Check for updates'));
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(find.textContaining('minisign signature verification failed'), findsOneWidget);
    expect(find.text('Download verified update'), findsNothing);
  });

  testWidgets('Built-in offline FAQ opens from Settings even without daemon (D-SET-31)', (tester) async {
    await pumpShell(tester, withDaemon: false);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Help & what values mean'));
    await tester.tap(find.text('Help & what values mean'));
    await tester.pumpAndSettle();

    expect(find.text('PROXY VS VPN (TUN) MODE'), findsOneWidget);
    expect(find.text('VERIFIED UPDATES (MINISIGN)'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Help & what values mean'), findsOneWidget);
  });

  testWidgets('SettingsScreen offers 1-click system service uninstall with confirmation and polkit fallback', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var uninstallCalls = 0;
    var switchedToUserMode = false;
    var nextExit = 127;
    final svc = ServiceController(
      mode: InstallMode.installed,
      installedWindowPath: '/opt/niko/niko',
      manualCommand: 'sudo /opt/niko/resources/daemon/niko-daemon service install',
      manualUninstallCommand: 'sudo /usr/local/libexec/niko/niko-daemon service uninstall',
      runElevatedUninstall: () async {
        uninstallCalls++;
        return InstallResult.exit(nextExit);
      },
      onUninstalledInPlace: () async {
        switchedToUserMode = true;
      },
    );
    final daemon = MemoryDaemon()
      ..api = 16
      ..groupRows = [const GroupRow(id: 1, name: '', ungrouped: true)];
    final controller = ConnectionController(daemon: daemon, loadConfig: null)..attach();
    final settings = WindowSettings.memory(advanced: true, language: 'en');
    addTearDown(() {
      svc.dispose();
      controller.dispose();
      settings.dispose();
    });

    await tester.pumpWidget(
      NikoApp(
        controller: controller,
        settings: settings,
        locale: const Locale('en'),
        serviceInstall: svc,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('System service'), findsOneWidget);
    expect(find.text('Installed (VPN / TUN available)'), findsOneWidget);

    // Clicking Uninstall asks for confirmation first.
    await tester.ensureVisible(find.text('Uninstall service'));
    await tester.tap(find.text('Uninstall service'));
    await tester.pumpAndSettle();
    expect(find.text('Uninstall system service?'), findsOneWidget);

    // 1. Polkit unavailable (exit 127) shows copyable sudo uninstall command.
    await tester.tap(find.text('Uninstall service').last);
    await tester.pumpAndSettle();
    expect(uninstallCalls, 1);
    expect(find.textContaining('sudo /usr/local/libexec/niko/niko-daemon service uninstall'), findsOneWidget);
    expect(find.text('Copy command'), findsOneWidget);
    expect(svc.mode, InstallMode.installed);

    // 2. Successful uninstall (exit 0) switches to notInstalled and runs onUninstalledInPlace.
    nextExit = 0;
    await tester.tap(find.text('Uninstall service'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uninstall service').last);
    await tester.pumpAndSettle();
    expect(uninstallCalls, 2);
    expect(switchedToUserMode, isTrue);
    expect(svc.mode, InstallMode.notInstalled);
    expect(find.text('System service uninstalled'), findsOneWidget);
    expect(find.text('Not installed (Proxy only)'), findsOneWidget);
    expect(find.text('Install service'), findsOneWidget);
  });
}
