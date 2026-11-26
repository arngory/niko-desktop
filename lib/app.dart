import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'platform/service_install.dart';
import 'platform/user_store_migration.dart';
import 'screens/shell.dart';
import 'state/connection_controller.dart';
import 'state/window_settings.dart';
import 'theme/niko_theme.dart';

const _windowChannel = MethodChannel('niko/window');

/// The window: the design system's theme by the user's or system's light/dark, and the shell with its sections.
class NikoApp extends StatefulWidget {
  const NikoApp({
    super.key,
    required this.controller,
    this.settings,
    this.saveTo,
    this.daemonAddress = '',
    this.configName = '',
    this.locale,
    this.brightness,
    this.now = DateTime.now,
    this.serviceInstall,
    this.userMigration,
  });

  final ConnectionController controller;

  /// What the window remembers between launches; null: nothing kept (tests).
  final WindowSettings? settings;

  /// Where files the user asks for are saved; null: the user's Downloads (tests give their own).
  final Directory? Function()? saveTo;
  final String daemonAddress;
  final String configName;

  /// For tests; the window setting or the system's otherwise.
  final Locale? locale;
  final Brightness? brightness;
  final DateTime Function() now;
  final ServiceController? serviceInstall;
  final UserStoreMigrationController? userMigration;

  @override
  State<NikoApp> createState() => _NikoAppState();
}

class _NikoAppState extends State<NikoApp> {
  WindowSettings? _ownedSettings;
  bool? _lastChromeDark;

  WindowSettings get _settings => widget.settings ?? (_ownedSettings ??= WindowSettings.memory());

  @override
  void didUpdateWidget(NikoApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settings != null && _ownedSettings != null) {
      _ownedSettings!.dispose();
      _ownedSettings = null;
    }
  }

  @override
  void dispose() {
    _ownedSettings?.dispose();
    super.dispose();
  }

  void _syncWindowChrome(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    if (_lastChromeDark == dark) return;
    _lastChromeDark = dark;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_windowChannel.invokeMethod<void>('setDark', dark).catchError((Object _) {}));
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final locale = settings.language == 'system' ? widget.locale : Locale(settings.language);
        return WidgetsApp(
          title: 'Niko',
          debugShowCheckedModeBanner: false,
          color: NikoColors.dark.surface0,
          locale: locale,
          supportedLocales: const [Locale('en'), Locale('ru')],
          textStyle: NikoType.body.style(NikoColors.dark.ink),
          pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
              PageRouteBuilder<T>(settings: settings, pageBuilder: (context, _, _) => builder(context)),
          home: Builder(
            builder: (context) {
              final effectiveBrightness = switch (settings.theme) {
                'light' => Brightness.light,
                'dark' => Brightness.dark,
                _ => widget.brightness ?? MediaQuery.platformBrightnessOf(context),
              };
              _syncWindowChrome(effectiveBrightness);
              final colors = NikoTheme.forBrightness(effectiveBrightness);
              return NikoTheme(
                colors: colors,
                child: DefaultTextStyle(
                  style: NikoType.body.style(colors.ink),
                  child: NikoShell(
                    controller: widget.controller,
                    settings: settings,
                    saveTo: widget.saveTo,
                    daemonAddress: widget.daemonAddress,
                    configName: widget.configName,
                    now: widget.now,
                    serviceInstall: widget.serviceInstall,
                    userMigration: widget.userMigration,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
