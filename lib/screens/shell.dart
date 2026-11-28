import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

import '../app_info.dart';
import '../daemon/daemon.dart';
import '../l10n/strings.dart';
import '../platform/config_backup.dart';
import '../platform/deep_link.dart';
import '../platform/desktop_integration.dart';
import '../platform/places.dart' as places;
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
import 'admin_screen.dart';
import 'check_screen.dart';
import 'connections_screen.dart';
import 'faq_screen.dart';
import 'log_screen.dart';
import 'main_screen.dart';
import 'nodes_screen.dart';
import 'rules_screen.dart';
import 'why_screen.dart';

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
    this.desktop,
    this.initialImportLink,
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
  final DesktopIntegration? desktop;
  final String? initialImportLink;

  @override
  State<NikoShell> createState() => _NikoShellState();
}

class _NikoShellState extends State<NikoShell> {
  late AppLifecycleListener _lifecycle;
  late DesktopIntegration _desktop;
  late LogFeed _log;
  late ConnectionsFeed _connections;
  late StunTool _stun;
  late ProfilesFeed _profiles;
  late RulesFeed _rules;
  late SettingsFeed _settings;
  late RouteCheckController _routeCheck;
  bool _adding = false;
  int _addSession = 0;
  String _initialImportLink = '';
  bool _showingFaq = false;
  NodeRow? _whyNode;
  NodeRow? _adminNode;
  AppSection _section = AppSection.home;
  late bool _advanced = widget.settings.advanced;
  bool _localeSynced = false;
  bool _reloadNeeded = false;
  bool _networkRestored = false;
  Timer? _networkRestoredTimer;
  LinkPhase? _lastLink;
  ServicePhase? _lastPhase;
  bool _startupConnectTried = false;
  String _lastTraySig = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialImportLink != null && widget.initialImportLink!.trim().isNotEmpty) {
      _initialImportLink = widget.initialImportLink!.trim();
      _section = AppSection.nodes;
      _adding = true;
    }
    _desktop = widget.desktop ?? DesktopIntegration();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    _lastLink = widget.controller.link;
    _lastPhase = widget.controller.service.phase;
    widget.settings.addListener(_onWindowSettings);
    _desktop.setTrayActionHandler(_onTrayAction);
    _desktop.setDeepLinkHandler(_onDeepLink);
    unawaited(_desktop.setCloseToTray(widget.settings.closeToTray));
    _attach();
    _read();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTray());
  }

  void _onDeepLink(String raw) {
    final normalized = normalizeDeepLink(raw);
    if (normalized == null || !mounted) return;
    setState(() {
      _section = AppSection.nodes;
      _adding = true;
      _addSession++;
      _initialImportLink = normalized;
      _whyNode = null;
      _adminNode = null;
      _showingFaq = false;
    });
    _read();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTray();
  }

  void _onWindowSettings() {
    unawaited(_desktop.setCloseToTray(widget.settings.closeToTray));
  }

  void _onTrayAction(String action) {
    switch (action) {
      case 'toggle':
        if (widget.controller.link == LinkPhase.ready && !widget.controller.busy) {
          unawaited(widget.controller.toggle(mode: _mode()));
        }
      case 'toggleMode':
        if (widget.controller.link == LinkPhase.ready && !widget.controller.busy) {
          final current = _mode() ?? ConnectMode.proxy;
          final next = current == ConnectMode.vpn ? ConnectMode.proxy : ConnectMode.vpn;
          if (next == ConnectMode.vpn && !widget.controller.tunAvailable) return;
          _setMode(next);
        }
      case 'show':
        unawaited(_desktop.showWindow());
      case 'quit':
        unawaited(_quitGracefully());
    }
  }

  Future<void> _quitGracefully() async {
    await _onExitRequested();
    await _desktop.closeWindow();
  }

  Directory? _resolvedSaveDirectory() {
    final custom = widget.settings.saveDirectory.trim();
    if (custom.isNotEmpty) return Directory(custom);
    return places.saveDirectory();
  }

  void _onSettingsMutated(Iterable<String> keys) {
    if (widget.controller.service.phase != ServicePhase.started) return;
    if (keys.every((k) => k == 'serviceMode')) return;
    if (!_reloadNeeded && mounted) setState(() => _reloadNeeded = true);
  }

  void _onRulesMutated() {
    if (widget.controller.service.phase != ServicePhase.started) return;
    if (!_reloadNeeded && mounted) setState(() => _reloadNeeded = true);
  }

  Future<void> _reconnect() async {
    await widget.controller.reconnect(mode: _mode());
    if (mounted && widget.controller.actionError.isEmpty && _reloadNeeded) {
      setState(() => _reloadNeeded = false);
    }
  }

  void _maybeAutoConnect() {
    if (_startupConnectTried || !widget.settings.connectOnStartup) return;
    final state = widget.controller;
    if (state.link != LinkPhase.ready || !state.connectsProfile) return;
    if (!_profiles.loaded || !_settings.loaded) return;
    _startupConnectTried = true;
    if (state.service.phase == ServicePhase.idle && !state.busy && _profiles.selected != 0) {
      unawaited(state.toggle(mode: _mode()));
    }
  }

  void _syncTray() {
    if (!mounted) return;
    final strings = NikoStrings.of(Localizations.localeOf(context));
    final state = widget.controller;
    final connected = state.link == LinkPhase.ready && state.service.phase == ServicePhase.started;
    final statusLabel = connected
        ? strings.statusOn
        : state.service.phase == ServicePhase.starting
            ? strings.statusConnecting
            : strings.statusOff;
    final profileName = _profiles.selectedProfile?.name ?? '';
    final toggleLabel = connected ? strings.disconnect : strings.connect;
    final currentMode = _mode();
    final modeLabel = currentMode == null
        ? ''
        : currentMode == ConnectMode.vpn
            ? strings.trayModeVpn
            : strings.trayModeProxy;
    final sig = '$connected|$statusLabel|$profileName|$toggleLabel|$modeLabel|${strings.trayOpen}|${strings.trayQuit}';
    if (sig == _lastTraySig) return;
    _lastTraySig = sig;
    unawaited(_desktop.updateTray(
      connected: connected,
      statusLabel: statusLabel,
      profileName: profileName,
      toggleLabel: toggleLabel,
      modeLabel: modeLabel,
      openLabel: strings.trayOpen,
      quitLabel: strings.trayQuit,
    ));
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
    _log = LogFeed(widget.controller, saveTo: widget.saveTo ?? _resolvedSaveDirectory);
    _connections = ConnectionsFeed(widget.controller);
    _stun = StunTool(widget.controller);
    _profiles = ProfilesFeed(widget.controller);
    _rules = RulesFeed(widget.controller, onMutated: _onRulesMutated);
    _settings = SettingsFeed(widget.controller, onMutated: _onSettingsMutated);
    _routeCheck = RouteCheckController(widget.controller, widget.settings);
    _profiles.addListener(_onFeedChanged);
    _settings.addListener(_onFeedChanged);
    widget.controller.addListener(_changed);
  }

  void _onFeedChanged() {
    _maybeAutoConnect();
    _syncTray();
  }

  void _detach(ConnectionController controller) {
    controller.removeListener(_changed);
    _profiles.removeListener(_onFeedChanged);
    _settings.removeListener(_onFeedChanged);
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
    if (oldWidget.settings != widget.settings) {
      oldWidget.settings.removeListener(_onWindowSettings);
      widget.settings.addListener(_onWindowSettings);
      unawaited(_desktop.setCloseToTray(widget.settings.closeToTray));
    }
    if (oldWidget.controller != widget.controller) {
      _detach(oldWidget.controller);
      _attach();
      _read();
    }
  }

  @override
  void dispose() {
    _networkRestoredTimer?.cancel();
    _desktop.setTrayActionHandler(null);
    _desktop.setDeepLinkHandler(null);
    widget.settings.removeListener(_onWindowSettings);
    _lifecycle.dispose();
    _detach(widget.controller);
    super.dispose();
  }

  // the connections screen says whether the core runs; the settings, whether the daemon is there
  void _changed() {
    final state = widget.controller;
    final prevLink = _lastLink;
    final prevPhase = _lastPhase;
    _lastLink = state.link;
    _lastPhase = state.service.phase;

    if (prevLink == LinkPhase.lost && state.link == LinkPhase.ready) {
      _networkRestoredTimer?.cancel();
      _networkRestored = true;
      _networkRestoredTimer = Timer(const Duration(seconds: 6), () {
        if (mounted && _networkRestored) setState(() => _networkRestored = false);
      });
      if (mounted) setState(() {});
    }

    if (state.service.phase != ServicePhase.started && _reloadNeeded) {
      _reloadNeeded = false;
      if (mounted) setState(() {});
    }

    if (widget.settings.notifications && prevPhase != state.service.phase && mounted) {
      final strings = NikoStrings.of(Localizations.localeOf(context));
      if (state.link == LinkPhase.ready && state.service.phase == ServicePhase.started) {
        final profile = _profiles.selectedProfile?.name ?? '';
        unawaited(_desktop.notify(
          title: 'Niko',
          body: profile.isNotEmpty ? '${strings.statusOn} · $profile' : strings.statusOn,
        ));
      } else if (state.link == LinkPhase.ready && state.service.phase == ServicePhase.fatal) {
        final err = state.service.error.isNotEmpty ? state.service.error : strings.statusError;
        unawaited(_desktop.notify(title: 'Niko', body: err));
      }
    }

    if (state.link == LinkPhase.ready) {
      if (!_localeSynced) {
        _localeSynced = true;
        final lang = widget.settings.language;
        if (lang != 'system') {
          final daemon = state.daemon;
          if (daemon != null) unawaited(daemon.setLocale(lang).catchError((Object _) {}));
        }
      }
    } else {
      _localeSynced = false;
    }
    _maybeAutoConnect();
    _syncTray();
    if (_section == AppSection.connections || _section == AppSection.settings) setState(() {});
    // the daemon found, or another one: whether the main screen reads the settings
    if (_section == AppSection.home) _read();
  }

  // each feed reads the daemon only while its screen is the one shown
  void _read() {
    _section == AppSection.log ? _log.open() : _log.close();
    _section == AppSection.connections ? _connections.show() : _connections.hide();
    // main screen (D-MAIN-13), rules (profile outbound picker), and route check read profiles too
    _section == AppSection.nodes ||
            _section == AppSection.home ||
            _section == AppSection.check ||
            _section == AppSection.rules
        ? _profiles.show()
        : _profiles.hide();
    _section == AppSection.rules || _section == AppSection.check ? _rules.show() : _rules.hide();
    // main screen (D-NAV-02), route check (serviceMode -> inbound/resolve), and log (Clash API card) read settings too
    _section == AppSection.settings ||
            _section == AppSection.check ||
            _section == AppSection.log ||
            (_section == AppSection.home && widget.controller.connectsProfile)
        ? _settings.show()
        : _settings.hide();
  }

  void _show(AppSection section) {
    if (section == _section) return;
    setState(() {
      _section = section;
      _adding = false;
      _initialImportLink = '';
      _showingFaq = false;
      _whyNode = null;
      _adminNode = null;
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
                  selectedProfile: _profiles.selectedProfile,
                  onOpenNodes: () => _show(AppSection.nodes),
                  onWhyNode: state.nikoApi >= 15
                      ? (n) {
                          setState(() {
                            _section = AppSection.nodes;
                            _whyNode = n;
                            _adminNode = null;
                            _adding = false;
                          });
                          _read();
                        }
                      : null,
                  daemonAddress: widget.daemonAddress,
                  configName: widget.configName,
                  now: widget.now,
                  mode: _mode(),
                  onMode: _setMode,
                  serviceInstall: widget.serviceInstall,
                  userMigration: widget.userMigration,
                  windowSettings: widget.settings,
                  reloadNeeded: _reloadNeeded,
                  onReconnect: () => unawaited(_reconnect()),
                  networkRestored: _networkRestored,
                  onClearSwitched: (id) => unawaited(_profiles.clearNodeSwitched(id)),
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
                builder: (context, _) {
                  final daemon = state.daemon;
                  if (_whyNode case final node? when daemon != null) {
                    return WhyScreen(
                      daemon: daemon,
                      node: node,
                      saveTo: widget.saveTo ?? _resolvedSaveDirectory,
                      now: widget.now,
                      onSwitchToName: (name) {
                        unawaited(() async {
                          final list = _profiles.groupId == node.groupId
                              ? _profiles.profiles
                              : await daemon.profiles(groupId: node.groupId);
                          final target = list.where((p) => p.groupId == node.groupId && p.name == name).firstOrNull;
                          if (target != null && mounted) {
                            await _profiles.select(target.id);
                            if (mounted) setState(() => _whyNode = null);
                          }
                        }());
                      },
                      onBack: () => setState(() => _whyNode = null),
                    );
                  }
                  if (_adminNode case final node? when daemon != null) {
                    return AdminScreen(
                      daemon: daemon,
                      node: node,
                      onBack: () => setState(() => _adminNode = null),
                    );
                  }
                  return _adding
                      ? AddScreen(
                          key: ValueKey('add-$_addSession'),
                          feed: _profiles,
                          initialText: _initialImportLink,
                          onDone: (_) => setState(() {
                            _adding = false;
                            _initialImportLink = '';
                          }),
                        )
                      : NodesScreen(
                          feed: _profiles,
                          linked: state.link == LinkPhase.ready,
                          onAdd: () => setState(() {
                            _initialImportLink = '';
                            _addSession++;
                            _adding = true;
                          }),
                          onWhy: state.nikoApi >= 15 ? (n) => setState(() => _whyNode = n) : null,
                          onAdmin: state.nikoApi >= 15 ? (n) => setState(() => _adminNode = n) : null,
                        );
                },
              ),
              AppSection.rules => ListenableBuilder(
                listenable: Listenable.merge([_rules, _profiles, state]),
                builder: (context, _) => RulesScreen(
                  feed: _rules,
                  linked: state.link == LinkPhase.ready,
                  profiles: _profiles.profiles,
                  extendedPresets: state.nikoApi >= 16,
                ),
              ),
              AppSection.log => ListenableBuilder(
                listenable: _settings,
                builder: (context, _) => LogScreen(
                  feed: _log,
                  stun: _stun,
                  clashApiEnabled: _settings.flag('enableClashAPI') && _settings.text('clashApi').trim().isNotEmpty,
                ),
              ),
              AppSection.settings => IndexedStack(
                index: _showingFaq ? 1 : 0,
                children: [
                  ListenableBuilder(
                    listenable: _settings,
                    builder: (context, _) {
                      final daemon = state.daemon;
                      final canUpdate = daemon != null && state.link == LinkPhase.ready && state.nikoApi >= 16;
                      return SettingsScreen(
                        values: _settings,
                        window: widget.settings,
                        advanced: _advanced,
                        nikoApi: state.link == LinkPhase.ready ? state.nikoApi : 18,
                        yggdrasilAddress: state.link == LinkPhase.ready ? state.yggdrasilAddress : '',
                        strings: strings,
                        coreVersion: state.link == LinkPhase.ready ? state.coreVersion : '',
                        nikoVersion: state.link == LinkPhase.ready ? state.nikoVersion : '',
                        onCheckUpdate: canUpdate
                            ? () => daemon.checkUpdate(currentVersion: windowVersion)
                            : null,
                        onDownloadUpdate: canUpdate
                            ? (tag) => daemon.downloadUpdate(
                                  tag: tag,
                                  currentVersion: windowVersion,
                                  destDir: (widget.saveTo ?? _resolvedSaveDirectory)(),
                                )
                            : null,
                        onOpenFaq: () => setState(() => _showingFaq = true),
                        serviceInstall: widget.serviceInstall,
                        onExportBackup: daemon != null && state.link == LinkPhase.ready
                            ? () {
                                final dir = (widget.saveTo ?? _resolvedSaveDirectory)() ?? Directory.systemTemp;
                                return exportDesktopBackup(
                                  daemon: daemon,
                                  destDir: dir,
                                  windowSettings: widget.settings,
                                  now: widget.now(),
                                );
                              }
                            : null,
                        onImportBackup: daemon != null && state.link == LinkPhase.ready
                            ? (jsonText) => importDesktopBackupJson(
                                  daemon: daemon,
                                  jsonText: jsonText,
                                  windowSettings: widget.settings,
                                )
                            : null,
                        onLanguage: (lang) {
                          final d = state.daemon;
                          if (d != null && state.link == LinkPhase.ready) {
                            unawaited(d.setLocale(lang == 'system' ? '' : lang).catchError((Object _) {}));
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
                      );
                    },
                  ),
                  FaqScreen(onBack: () => setState(() => _showingFaq = false)),
                ],
              ),
            },
          ),
        ],
      ),
    );
  }
}
