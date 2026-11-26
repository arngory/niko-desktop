import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

import '../daemon/daemon.dart';
import '../l10n/strings.dart';
import '../platform/service_install.dart';
import '../platform/user_store_migration.dart';
import '../state/connection_controller.dart';
import '../state/connections_feed.dart';
import '../state/log_feed.dart';
import '../state/profiles_feed.dart';
import '../state/route_check.dart';
import '../state/rules_feed.dart';
import '../state/settings_feed.dart';
import '../state/stun_tool.dart';
import '../state/window_settings.dart';
import '../theme/niko_theme.dart';
import '../settings/settings_screen.dart';
import '../ui/header.dart';
import 'add_screen.dart';
import 'check_screen.dart';
import 'connections_screen.dart';
import 'log_screen.dart';
import 'main_screen.dart';
import 'nodes_screen.dart';
import 'rules_screen.dart';

/// The sections the window has, in the canvas's order.
enum AppSection { home, nodes, check, connections, rules, log, settings }

/// The window under its header: the section shown, in the view chosen. D-NAV-01, D-NAV-03.
///
/// Простой shows the main screen and the log; Расширенный adds the rules and the connections. Changing the view
/// changes what is shown and nothing about the connection.
class NikoShell extends StatefulWidget {
  const NikoShell({
    super.key,
    required this.controller,
    required this.settings,
    this.saveTo,
    this.daemonAddress = '',
    this.configName = '',
    this.now = DateTime.now,
    this.serviceInstall,
    this.userMigration,
  });

  final ConnectionController controller;

  /// The view chosen is kept in it, for the next launch.
  final WindowSettings settings;

  /// Where the log and the reports are saved; null: the user's Downloads.
  final Directory? Function()? saveTo;
  final String daemonAddress;
  final String configName;
  final DateTime Function() now;
  final ServiceController? serviceInstall;
  final UserStoreMigrationController? userMigration;

  @override
  State<NikoShell> createState() => _NikoShellState();
}

class _NikoShellState extends State<NikoShell> {
  late AppLifecycleListener _lifecycle;
  late LogFeed _log;
  late ConnectionsFeed _connections;
  late StunTool _stun;
  late ProfilesFeed _profiles;
  late RulesFeed _rules;
  late SettingsFeed _settings;
  late RouteCheckController _routeCheck;
  bool _adding = false;
  AppSection _section = AppSection.home;
  late bool _advanced = widget.settings.advanced;
  bool _localeSynced = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    _attach();
    _read();
  }

  // finish any queued settings write before closing; in user-mode also shut down the unprivileged
  // daemon cleanly so GNOME/KDE/WinINet system proxy settings are restored (the system service stays up).
  Future<AppExitResponse> _onExitRequested() async {
    try {
      await widget.settings.flush().timeout(const Duration(seconds: 1));
    } catch (_) {
      // a stalled or failed write never blocks closing the window
    }
    if (widget.controller.isUserMode) {
      final daemon = widget.controller.daemon;
      if (daemon != null) {
        try {
          await daemon.stop().timeout(const Duration(seconds: 2));
        } catch (_) {}
        try {
          await daemon.close().timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    }
    return AppExitResponse.exit;
  }

  void _attach() {
    _log = LogFeed(widget.controller, saveTo: widget.saveTo);
    _connections = ConnectionsFeed(widget.controller);
    _stun = StunTool(widget.controller);
    _profiles = ProfilesFeed(widget.controller);
    _rules = RulesFeed(widget.controller);
    _settings = SettingsFeed(widget.controller);
    _routeCheck = RouteCheckController(widget.controller, widget.settings);
    widget.controller.addListener(_changed);
  }

  void _detach(ConnectionController controller) {
    controller.removeListener(_changed);
    _log.dispose();
    _connections.dispose();
    _stun.dispose();
    _profiles.dispose();
    _rules.dispose();
    _settings.dispose();
    _routeCheck.dispose();
  }

  @override
  void didUpdateWidget(NikoShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _detach(oldWidget.controller);
      _attach();
      _read();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _detach(widget.controller);
    super.dispose();
  }

  // the connections screen says whether the core runs; the settings, whether the daemon is there
  void _changed() {
    if (widget.controller.link == LinkPhase.ready) {
      if (!_localeSynced) {
        _localeSynced = true;
        final lang = widget.settings.language;
        if (lang != 'system') {
          final daemon = widget.controller.daemon;
          if (daemon != null) unawaited(daemon.setLocale(lang).catchError((Object _) {}));
        }
      }
    } else {
      _localeSynced = false;
    }
    if (_section == AppSection.connections || _section == AppSection.settings) setState(() {});
    // the daemon found, or another one: whether the main screen reads the settings
    if (_section == AppSection.home) _read();
  }

  // each feed reads the daemon only while its screen is the one shown
  void _read() {
    _section == AppSection.log ? _log.open() : _log.close();
    _section == AppSection.connections ? _connections.show() : _connections.hide();
    // main screen (D-MAIN-13) and route check (selected profile/group label) read profiles too
    _section == AppSection.nodes || _section == AppSection.home || _section == AppSection.check
        ? _profiles.show()
        : _profiles.hide();
    _section == AppSection.rules || _section == AppSection.check ? _rules.show() : _rules.hide();
    // main screen (D-NAV-02) and route check (serviceMode -> inbound/resolve) read settings too
    _section == AppSection.settings ||
            _section == AppSection.check ||
            (_section == AppSection.home && widget.controller.connectsProfile)
        ? _settings.show()
        : _settings.hide();
  }

  void _show(AppSection section) {
    if (section == _section) return;
    setState(() {
      _section = section;
      _adding = false;
    });
    // the section Узлы reads the store anew, as when it was not followed on the main screen
    if (section == AppSection.nodes) _profiles.hide();
    _read();
  }

  void _setAdvanced(bool advanced) {
    if (advanced == _advanced) return;
    widget.settings.advanced = advanced;
    unawaited(widget.settings.save());
    setState(() {
      _advanced = advanced;
      // a section the simple view does not have gives way to the main screen
      if (!advanced && (_section == AppSection.connections || _section == AppSection.rules)) _section = AppSection.home;
    });
    _read();
  }

  // the settings' mode, once read
  ConnectMode? _mode() => !_settings.loaded
      ? null
      : _settings.text('serviceMode') == 'vpn'
          ? ConnectMode.vpn
          : ConnectMode.proxy;

  // kept as the settings' mode, and a running core started again in it
  void _setMode(ConnectMode mode) {
    _settings.setText('serviceMode', mode.name);
    unawaited(widget.controller.switchMode(mode));
  }

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final strings = NikoStrings.of(Localizations.localeOf(context));
    final state = widget.controller;
    return ColoredBox(
      color: colors.surface0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NikoHeader<AppSection>(
            sectionsLabel: strings.sections,
            sections: [
              (AppSection.home, strings.sectionHome),
              (AppSection.nodes, strings.sectionNodes),
              (AppSection.check, strings.sectionCheck),
              if (_advanced) (AppSection.connections, strings.sectionConnections),
              if (_advanced) (AppSection.rules, strings.sectionRules),
              (AppSection.log, strings.sectionLog),
              (AppSection.settings, strings.sectionSettings),
            ],
            section: _section,
            onSection: _show,
            viewLabel: strings.view,
            views: (strings.viewSimple, strings.viewAdvanced),
            advanced: _advanced,
            onAdvanced: _setAdvanced,
          ),
          Expanded(
            child: switch (_section) {
              AppSection.home => ListenableBuilder(
                listenable: Listenable.merge([_settings, _profiles]),
                builder: (context, _) => MainScreen(
                  controller: state,
                  node: _profiles.selectedNode,
                  daemonAddress: widget.daemonAddress,
                  configName: widget.configName,
                  now: widget.now,
                  mode: _mode(),
                  onMode: _setMode,
                  serviceInstall: widget.serviceInstall,
                  userMigration: widget.userMigration,
                ),
              ),
              AppSection.check => ListenableBuilder(
                listenable: Listenable.merge([_routeCheck, _profiles, _rules, _settings, state, widget.settings]),
                builder: (context, _) {
                  final vpnMode = state.startedMode != null
                      ? state.startedMode == ConnectMode.vpn
                      : _mode() == ConnectMode.vpn;
                  return CheckScreen(
                    check: _routeCheck,
                    controller: state,
                    profiles: _profiles,
                    rules: _rules,
                    vpnMode: vpnMode,
                    advanced: _advanced,
                    now: widget.now,
                  );
                },
              ),
              AppSection.connections => ConnectionsScreen(
                feed: _connections,
                running: state.link == LinkPhase.ready && state.service.phase == ServicePhase.started,
                now: widget.now,
              ),
              AppSection.nodes => ListenableBuilder(
                listenable: Listenable.merge([_profiles, state]),
                builder: (context, _) => _adding
                    ? AddScreen(feed: _profiles, onDone: (_) => setState(() => _adding = false))
                    : NodesScreen(
                        feed: _profiles,
                        linked: state.link == LinkPhase.ready,
                        onAdd: () => setState(() => _adding = true),
                      ),
              ),
              AppSection.rules => ListenableBuilder(
                listenable: Listenable.merge([_rules, state]),
                builder: (context, _) => RulesScreen(feed: _rules, linked: state.link == LinkPhase.ready),
              ),
              AppSection.log => LogScreen(feed: _log, stun: _stun),
              AppSection.settings => ListenableBuilder(
                listenable: _settings,
                builder: (context, _) => SettingsScreen(
                  values: _settings,
                  window: widget.settings,
                  strings: strings,
                  coreVersion: state.link == LinkPhase.ready ? state.coreVersion : '',
                  nikoVersion: state.link == LinkPhase.ready ? state.nikoVersion : '',
                  onLanguage: (lang) {
                    final daemon = state.daemon;
                    if (daemon != null && state.link == LinkPhase.ready) {
                      unawaited(daemon.setLocale(lang == 'system' ? '' : lang).catchError((Object _) {}));
                    }
                  },
                  notice: switch (state.link) {
                    LinkPhase.ready when _settings.loaded => null,
                    LinkPhase.ready when _settings.readError.isNotEmpty => (
                      strings.settingsUnread,
                      _settings.readError,
                    ),
                    // read in a moment: nothing to say yet
                    LinkPhase.ready => ('', ''),
                    _ => (strings.storeNoLink, ''),
                  },
                ),
              ),
            },
          ),
        ],
      ),
    );
  }
}
