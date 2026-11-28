import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';

import '../app_info.dart';
import '../daemon/daemon.dart';
import '../l10n/strings.dart';
import '../platform/autostart.dart';
import '../platform/config_backup.dart';
import '../platform/desktop_integration.dart';
import '../platform/service_install.dart';
import '../state/window_settings.dart';
import '../theme/niko_theme.dart';
import '../ui/banner.dart';
import '../ui/controls.dart';
import '../ui/dialog.dart';
import '../ui/fields.dart';
import '../ui/icons.dart';
import '../ui/list.dart';
import '../ui/pressable.dart';
import 'setting_values.dart';

/// Настройки (B-Settings): 12-section desktop mockup parity + Simple/Advanced mode filtering.
/// The window's own choices (theme, language, autostart, tray, exit service, speed interval, server address,
/// auto-update check) are always available; daemon settings come from `NikoService.GetSettings` (API 18).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.values,
    required this.strings,
    this.window,
    this.advanced = true,
    this.nikoApi = 18,
    this.yggdrasilAddress = '',
    this.onLanguage,
    this.coreVersion = '',
    this.nikoVersion = '',
    this.notice,
    this.autostart,
    this.pickDirectory,
    this.onCheckUpdate,
    this.onDownloadUpdate,
    this.onOpenFaq,
    this.serviceInstall,
    this.onExportBackup,
    this.onImportBackup,
    this.pickBackupFile,
  });

  /// The settings by the app's names (SettingsFeed: the daemon's).
  final SettingValues values;
  final NikoStrings strings;

  /// The window's own remembered choices (theme, language, etc.); null: kept in memory.
  final WindowSettings? window;

  /// When false (Simple mode), only the basic subset of settings is displayed.
  final bool advanced;

  /// Connected daemon's NikoService API level; gates API 18 rows so older API 17 daemons never get unknown keys.
  final int nikoApi;

  /// Device's persistent Yggdrasil 200::/7 IPv6 address (API 18 Info.yggdrasil_address).
  final String yggdrasilAddress;

  /// Called after the user saves a language choice, so the shell can inform the daemon.
  final ValueChanged<String>? onLanguage;

  /// Connected daemon's core and nikod versions (shown under About when non-empty).
  final String coreVersion;
  final String nikoVersion;

  /// Notice shown in place of daemon sections when daemon is unreachable or settings unread.
  final (String, String)? notice;

  /// Optional autostart manager override (D-SET-04).
  final DesktopAutostart? autostart;

  /// Optional native directory picker override (used for save folder selection).
  final Future<String?> Function()? pickDirectory;

  /// Optional verified updater callbacks (D-SET-12/33, BG-12).
  final Future<UpdateCheckResult> Function()? onCheckUpdate;
  final Future<UpdateDownloadResult> Function(String tag)? onDownloadUpdate;

  /// Optional built-in offline FAQ navigation callback (D-SET-31).
  final VoidCallback? onOpenFaq;

  /// Optional system service install/uninstall controller (Linux pkexec / Windows UAC).
  final ServiceController? serviceInstall;

  /// Optional portable configuration backup export/import callbacks.
  final Future<BackupExportSummary> Function()? onExportBackup;
  final Future<BackupImportSummary> Function(String jsonText)? onImportBackup;
  final Future<String?> Function()? pickBackupFile;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// All sections in B-Settings.dc.html order (plus desktop Programs right after DNS).
enum _Section {
  general,
  raycontrol,
  connection,
  dns,
  programs,
  inbound,
  naive,
  yggdrasil,
  experiments,
  log,
  backup,
  about,
  help,
}

/// A dialog of a settings row: a daemon value row (fields or domain strategies) or the window's language choice.
class _Dialog {
  const _Dialog(this.title, this.fields, {this.hint = '', this.strategies = false, this.language = false});

  final String title;
  final List<(String, String, FieldInput)> fields;
  final String hint;
  final bool strategies;
  final bool language;
}

const _strategyKeys = ['domainStrategyForRemote', 'domainStrategyForDirect', 'domainStrategyForServer'];
const _strategies = ['auto', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'];

class _SettingsScreenState extends State<SettingsScreen> {
  final _scroll = ScrollController();
  final _keys = {for (final s in _Section.values) s: GlobalKey()};
  WindowSettings? _ownedWindow;
  FocusNode? _returnFocus;
  _Section _current = _Section.general;
  _Dialog? _dialog;
  bool _autostartEnabled = false;
  late final DesktopAutostart _autostart = widget.autostart ?? DesktopAutostart();
  bool _checkingUpdate = false;
  bool _downloadingUpdate = false;
  UpdateCheckResult? _updateInfo;
  UpdateDownloadResult? _updateDownload;
  String _updateError = '';
  bool _confirmUninstallService = false;
  bool _confirmReset = false;
  bool _resetting = false;
  bool _backupBusy = false;
  String _backupMessage = '';
  bool _backupError = false;
  bool _copiedYggAddr = false;
  Timer? _yggCopyTimer;

  bool get _api18 => widget.nikoApi >= 18;

  Future<void> _exportBackup() async {
    final fn = widget.onExportBackup;
    if (fn == null || _backupBusy) return;
    setState(() {
      _backupBusy = true;
      _backupMessage = '';
      _backupError = false;
    });
    try {
      final summary = await fn();
      if (mounted) {
        setState(() {
          _backupMessage = _s.backupExported(summary.path, summary.profiles, summary.rules, summary.skippedNodes);
          _backupError = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _backupMessage = '${_s.backupFailed}: ${daemonError(e)}';
          _backupError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _importBackup() async {
    final fn = widget.onImportBackup;
    if (fn == null || _backupBusy) return;
    final picker = widget.pickBackupFile ??
        () => DesktopIntegration().pickFile(title: _s.backupImport, extensions: const ['json']);
    final path = await picker();
    if (path == null || path.isEmpty || !mounted) return;
    setState(() {
      _backupBusy = true;
      _backupMessage = '';
      _backupError = false;
    });
    try {
      final file = File(path);
      const maxBackupBytes = 8 * 1024 * 1024;
      if (file.lengthSync() > maxBackupBytes) {
        throw const FormatException('backup file exceeds 8 MiB');
      }
      final jsonText = file.readAsStringSync();
      final summary = await fn(jsonText);
      if (mounted) {
        setState(() {
          _backupMessage = _s.backupImported(summary.groups, summary.profiles, summary.rules);
          _backupError = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _backupMessage = '${_s.backupFailed}: ${daemonError(e)}';
          _backupError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _resetSettings() async {
    if (_resetting) return;
    setState(() {
      _resetting = true;
      _confirmReset = false;
      _backupMessage = '';
      _backupError = false;
    });
    final err = await _v.reset();
    if (!mounted) return;
    setState(() {
      _resetting = false;
      if (err != null && err.isNotEmpty) {
        _backupMessage = err;
        _backupError = true;
      } else {
        _backupMessage = _s.setResetDone;
        _backupError = false;
      }
    });
  }

  WindowSettings get _window => widget.window ?? (_ownedWindow ??= WindowSettings.memory());

  Future<void> _checkUpdate() async {
    final fn = widget.onCheckUpdate;
    if (fn == null || _checkingUpdate) return;
    setState(() {
      _checkingUpdate = true;
      _updateError = '';
      _updateInfo = null;
      _updateDownload = null;
    });
    try {
      final info = await fn();
      if (mounted) setState(() => _updateInfo = info);
    } catch (e) {
      if (mounted) {
        setState(() {
          _updateInfo = null;
          _updateError = daemonError(e);
        });
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _downloadUpdate(String tag) async {
    final fn = widget.onDownloadUpdate;
    if (fn == null || _downloadingUpdate) return;
    setState(() {
      _downloadingUpdate = true;
      _updateError = '';
    });
    try {
      final dl = await fn(tag);
      if (mounted) setState(() => _updateDownload = dl);
    } catch (e) {
      if (mounted) setState(() => _updateError = daemonError(e));
    } finally {
      if (mounted) setState(() => _downloadingUpdate = false);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadAutostart());
  }

  Future<void> _loadAutostart() async {
    final on = await _autostart.isEnabled();
    if (mounted && on != _autostartEnabled) {
      setState(() => _autostartEnabled = on);
    }
  }

  Future<void> _setAutostart(bool enabled) async {
    try {
      await _autostart.setEnabled(enabled);
      if (mounted) setState(() => _autostartEnabled = enabled);
    } catch (_) {}
  }

  Future<void> _chooseSaveFolder() async {
    final picker = widget.pickDirectory ?? () => DesktopIntegration().pickDirectory(title: _s.setSaveFolder);
    final chosen = await picker();
    if (chosen != null && chosen.isNotEmpty) {
      _window.saveDirectory = chosen;
      unawaited(_window.save());
    }
  }

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.window != null && _ownedWindow != null) {
      _ownedWindow!.dispose();
      _ownedWindow = null;
    }
  }

  @override
  void dispose() {
    _yggCopyTimer?.cancel();
    _ownedWindow?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  NikoStrings get _s => widget.strings;
  SettingValues get _v => widget.values;

  void _openDialog(_Dialog dialog) {
    _returnFocus = FocusManager.instance.primaryFocus;
    setState(() => _dialog = dialog);
  }

  void _closeDialog() {
    final target = _returnFocus;
    _returnFocus = null;
    setState(() => _dialog = null);
    if (target != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && target.context != null && target.canRequestFocus) target.requestFocus();
      });
    }
  }

  String _languageName(String code) => switch (code) {
        'ru' => 'Русский',
        'en' => 'English',
        _ => _s.langSystem,
      };

  String _name(_Section section) => switch (section) {
        _Section.general => _s.setGeneral,
        _Section.raycontrol => _s.setRaycontrolNodes,
        _Section.connection => _s.setConnection,
        _Section.dns => _s.setDns,
        _Section.programs => _s.setPrograms,
        _Section.inbound => _s.setInboundMenu,
        _Section.naive => _s.setNaiveSection,
        _Section.yggdrasil => _s.setYggdrasilSection,
        _Section.experiments => _s.setExperiments,
        _Section.log => _s.setLogView,
        _Section.backup => _s.setBackupSection,
        _Section.about => _s.setAboutMenu,
        _Section.help => _s.setHelpSection,
      };

  void _jump(_Section section) {
    setState(() => _current = section);
    final target = _keys[section]!.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  String _strategy(String key) => _v.text(key).isEmpty ? 'auto' : _v.text(key);

  String _strategySummary() {
    final values = {for (final key in _strategyKeys) _strategy(key)};
    return values.length == 1 ? _s.strategy(values.single) : _s.setStrategyMixed;
  }

  String _dnsServers(String key) {
    final lines = [
      for (final line in _v.text(key).split('\n'))
        if (line.trim().isNotEmpty && !line.trim().startsWith('#')) line.trim(),
    ];
    if (lines.isEmpty) return _v.text(key).split('\n').first;
    final first = lines.first;
    final address = first.contains('://') ? first.substring(first.indexOf('://') + 3) : first;
    final slash = address.indexOf('/');
    final host = slash < 0 ? address : address.substring(0, slash);
    final shown = host.isEmpty ? first : host;
    return lines.length == 1 ? shown : '$shown +${lines.length - 1}';
  }

  String _programs() {
    final count = {for (final line in _v.text('programs').split('\n')) if (line.trim().isNotEmpty) line.trim()}.length;
    return count == 0 ? _s.setProgramsNone : _s.programsCount(count);
  }

  String _login() {
    if (_v.text('mixedPassword').isEmpty) return _s.setLoginNone;
    final user = _v.text('mixedUsername');
    return user.isEmpty ? _s.setLoginSet : user;
  }

  Widget _switch(String key, String title, {String? sub, bool divider = true}) => NikoSwitchRow(
        title: title,
        sub: sub,
        on: _v.flag(key),
        onChanged: (on) => _v.setFlag(key, on),
        divider: divider,
      );

  Widget _choice(String key, String title, List<(String, String)> choices, {double cell = 104, bool divider = true}) =>
      NikoChoiceRow<String>(
        title: title,
        choices: choices,
        value: _v.text(key),
        onChanged: (value) => _v.setText(key, value),
        cell: cell,
        divider: divider,
      );

  Widget _value(String title, String value, _Dialog dialog, {bool mono = true, bool divider = true}) => NikoLinkRow(
        title: title,
        value: value,
        mono: mono,
        divider: divider,
        onPressed: () => _openDialog(dialog),
      );

  Widget _section(_Section section, String overline, List<Widget> rows) =>
      KeyedSubtree(key: _keys[section], child: NikoSection(overline: overline, rows: rows));

  // 1. Общие
  Widget _generalSection({required bool withDaemon}) => _section(_Section.general, _s.setGeneral, [
        NikoChoiceRow<String>(
          title: _s.setTheme,
          choices: [('system', _s.themeSystem), ('light', _s.themeLight), ('dark', _s.themeDark)],
          value: _window.theme,
          onChanged: (value) {
            _window.theme = value;
            unawaited(_window.save());
          },
          cell: 136,
          divider: false,
        ),
        NikoLinkRow(
          title: _s.setLanguage,
          value: _languageName(_window.language),
          divider: true,
          onPressed: () => _openDialog(_Dialog(_s.setLanguage, const [], language: true)),
        ),
        NikoSwitchRow(
          title: _s.setAutostart,
          on: _autostartEnabled,
          divider: true,
          onChanged: (on) => unawaited(_setAutostart(on)),
        ),
        NikoSwitchRow(
          title: _s.setConnectOnStartup,
          sub: _s.setConnectLastMethod,
          on: _window.connectOnStartup,
          divider: true,
          onChanged: (on) {
            _window.connectOnStartup = on;
            unawaited(_window.save());
          },
        ),
        if (withDaemon) ...[
          _choice('serviceMode', _s.setMode, [('vpn', _s.setModeVpn), ('proxy', _s.setModeProxy)], cell: 96),
          _switch('systemProxy', _s.setSystemProxy, sub: _s.setSystemProxySub),
        ],
        if (widget.advanced) ...[
          NikoSwitchRow(
            title: _s.setCloseToTray,
            on: _window.closeToTray,
            divider: true,
            onChanged: (on) {
              _window.closeToTray = on;
              unawaited(_window.save());
            },
          ),
          NikoSwitchRow(
            title: _s.setNotifications,
            on: _window.notifications,
            divider: true,
            onChanged: (on) {
              _window.notifications = on;
              unawaited(_window.save());
            },
          ),
          NikoLinkRow(
            title: _s.setSaveFolder,
            value: _window.saveDirectory.isEmpty ? _s.setSaveFolderDefault : _window.saveDirectory,
            mono: _window.saveDirectory.isNotEmpty,
            divider: true,
            onPressed: () => unawaited(_chooseSaveFolder()),
          ),
        ],
        if (widget.serviceInstall case final svc?) _serviceRow(svc),
      ]);

  // 2. Узлы raycontrol
  Widget _raycontrolSection() => _section(_Section.raycontrol, _s.setRaycontrolNodes, [
        _switch('raycontrolAutoSwitch', _s.setRayAutoSwitch, sub: _s.setRayAutoSwitchSub, divider: false),
        if (widget.advanced) ...[
          _switch('raycontrolBrutal', _s.setRayBrutal, sub: _s.setRayBrutalSub),
          _value(
            _s.setRayDnsttResolver,
            _v.text('raycontrolDnsttResolver').isEmpty ? 'auto' : _v.text('raycontrolDnsttResolver'),
            _Dialog(_s.setRayDnsttResolver, [('raycontrolDnsttResolver', _s.setRayDnsttResolver, FieldInput.text)]),
          ),
          _value(
            _s.setRayMasterDnsResolvers,
            _v.text('raycontrolMasterDnsResolvers').isEmpty
                ? 'auto'
                : _v.text('raycontrolMasterDnsResolvers').split('\n').first,
            _Dialog(_s.setRayMasterDnsResolvers, [
              ('raycontrolMasterDnsResolvers', _s.setRayMasterDnsResolvers, FieldInput.lines),
            ]),
          ),
          _switch('raycontrolReports', _s.setRayReportsShort, sub: _s.setRayReportsNoAddr),
        ],
      ]);

  // 3. Подключение
  Widget _connectionSection() => _section(_Section.connection, _s.setConnection, [
        _choice('tunImplementation', _s.setTun, [('0', 'gVisor'), ('1', 'System'), ('2', 'Mixed')], cell: 88,
            divider: false),
        _value(_s.setMtu, _v.text('mtu'), _Dialog(_s.setMtu, [('mtu', _s.setMtu, FieldInput.port)], hint: _s.setMtuHint)),
        _choice('ipv6Mode', _s.setIpv6,
            [('0', _s.setIpv6Off), ('1', _s.setIpv6On), ('2', _s.setIpv6Prefer), ('3', _s.setIpv6Only)], cell: 84),
        _value(
          _s.setConnTestUrl,
          _v.text('connectionTestURL').isEmpty ? 'http://cp.cloudflare.com/' : _v.text('connectionTestURL'),
          _Dialog(_s.setConnTestUrl, [
            ('connectionTestURL', _s.setConnTestUrl, FieldInput.text),
            if (_api18) ('connectionTestConcurrency', _s.setConnTestConcurrency, FieldInput.port),
          ]),
        ),
        NikoChoiceRow<String>(
          title: _s.setExitService,
          choices: const [
            ('cloudflare', 'Cloudflare'),
            ('ipinfo', 'ipinfo'),
            ('ipwho', 'ipwho'),
            ('ipapi-co', 'ipapi'),
          ],
          value: _window.exitAddressService,
          onChanged: (value) {
            _window.exitAddressService = value;
            unawaited(_window.save());
          },
          cell: 88,
          divider: true,
        ),
        if (_api18) _switch('enableClashAPI', _s.setEnableClashApi, sub: _s.setClashApiHint),
        if (_api18 || _v.text('clashApi').isNotEmpty)
          _value(
            _s.setClashApiSecret,
            _v.text('clashApi').isEmpty ? '—' : '••••••••',
            _Dialog(_s.setClashApiSecret, [('clashApi', _s.setClashApiSecret, FieldInput.secret)],
                hint: _s.setClashApiHint),
          ),
        _switch('globalAllowInsecure', _s.setInsecure, sub: _s.setDangerous),
        if (_api18) ...[
          _switch('insecureSubscription', _s.setInsecureSubscription, sub: _s.setDangerous),
          _choice(
            'subscriptionMinTls',
            _s.setSubscriptionMinTls,
            [('', _s.setTlsAuto), ('1.2', 'TLS 1.2'), ('1.3', 'TLS 1.3')],
            cell: 84,
          ),
        ],
      ]);

  // 4. DNS и маршрут
  Widget _dnsSection() => _section(_Section.dns, _s.setDns, [
        if (widget.advanced) ...[
          _value(_s.setRemoteDns, _dnsServers('remoteDns'),
              _Dialog(_s.setRemoteDns, [('remoteDns', _s.setRemoteDns, FieldInput.lines)], hint: _s.setRemoteDnsHint),
              divider: false),
          _value(_s.setDirectDns, _v.text('directDns').split('\n').first,
              _Dialog(_s.setDirectDns, [('directDns', _s.setDirectDns, FieldInput.text)], hint: _s.setDnsHint)),
          _switch('enableFakeDns', _s.setFakeIp, sub: _s.setInVpn),
          _value(_s.setStrategy, _strategySummary(), _Dialog(_s.setStrategy, const [], strategies: true), mono: false),
          _switch('enableDnsRouting', _s.setEnableDnsRouting),
          _switch('dnsOptimisticCache', _s.setOptimisticCache),
          _switch('bypassLanInCore', _s.setLanDirect),
          _value(
            _s.setRuleSetHours,
            _v.text('ruleSetUpdateHours').isEmpty ? '24' : _v.text('ruleSetUpdateHours'),
            _Dialog(_s.setRuleSetHours, [('ruleSetUpdateHours', _s.setRuleSetHours, FieldInput.port)]),
          ),
        ] else ...[
          _switch('bypassLanInCore', _s.setLanDirect, divider: false),
        ],
      ]);

  // 5. Программы (desktop per-app routing)
  Widget _programsSection() => _section(_Section.programs, _s.setPrograms, [
        _choice('programsMode', _s.setProgramsThrough,
            [('0', _s.setProgramsAll), ('1', _s.setProgramsOnly), ('2', _s.setProgramsExcept)], cell: 148,
            divider: false),
        _value(
          _s.setProgramsList,
          _programs(),
          _Dialog(_s.setProgramsList, [('programs', _s.setProgramsList, FieldInput.lines)], hint: _s.setProgramsHint),
          mono: false,
        ),
      ]);

  // 6. Вход для других программ
  Widget _inboundSection() => _section(_Section.inbound, _s.setInbound, [
        _value(_s.inboundPort, _v.text('mixedPort'),
            _Dialog(_s.inboundPort, [('mixedPort', _s.inboundPort, FieldInput.port)]), divider: false),
        _value(
          _s.setLogin,
          _login(),
          _Dialog(_s.setLogin, [
            ('mixedUsername', _s.inboundUser, FieldInput.text),
            ('mixedPassword', _s.inboundPassword, FieldInput.secret),
          ], hint: _s.setLoginHint),
          mono: false,
        ),
        _switch('allowAccess', _s.setLanAccess),
      ]);

  // 7. naive
  Widget _naiveSection() => _section(_Section.naive, _s.setNaiveSection, [
        _choice(
          'rootStore',
          _s.setNaiveRoots,
          [('chrome', 'Chrome'), ('mozilla', 'Mozilla'), ('system', _s.setNaiveRootsSystem)],
          cell: 96,
          divider: false,
        ),
        if (_api18 && _v.text('rootStore') == 'system')
          _switch('naiveQuicPhoneRoots', _s.setNaiveQuicSystemRoots, sub: _s.setNaiveQuicSystemRootsSub),
      ]);

  // 8. Yggdrasil
  Widget _yggdrasilSection() {
    final addr = widget.yggdrasilAddress;
    return _section(_Section.yggdrasil, _s.setYggdrasilSection, [
      _switch('yggdrasilEnabled', _s.setYggdrasilEnable, divider: false),
      if (_v.flag('yggdrasilEnabled')) ...[
        _value(
          _s.setYggdrasilPeers,
          _v.text('yggdrasilPeers').isEmpty ? _s.setYggdrasilPeersAuto : _v.text('yggdrasilPeers').split('\n').first,
          _Dialog(_s.setYggdrasilPeers, [('yggdrasilPeers', _s.setYggdrasilPeers, FieldInput.lines)]),
          mono: _v.text('yggdrasilPeers').isNotEmpty,
        ),
        _switch('yggdrasilPeersViaProxy', _s.setYggdrasilViaProxy),
        _switch('yggdrasilTlsChrome', _s.setYggdrasilTlsChrome),
        _switch('yggdrasilAllowInbound', _s.setYggdrasilInbound),
        if (_v.flag('yggdrasilAllowInbound'))
          _value(
            _s.setYggdrasilInboundPorts,
            _v.text('yggdrasilInboundPorts').isEmpty ? '—' : _v.text('yggdrasilInboundPorts'),
            _Dialog(_s.setYggdrasilInboundPorts, [
              ('yggdrasilInboundPorts', _s.setYggdrasilInboundPorts, FieldInput.text),
            ]),
          ),
        NikoLinkRow(
          title: _s.setYggdrasilAddress,
          value: _copiedYggAddr
              ? _s.copiedShort
              : addr.isNotEmpty
                  ? addr
                  : _s.setYggdrasilAddressEmpty,
          mono: addr.isNotEmpty && !_copiedYggAddr,
          divider: true,
          onPressed: addr.isEmpty
              ? () {}
              : () {
                  unawaited(Clipboard.setData(ClipboardData(text: addr)));
                  setState(() => _copiedYggAddr = true);
                  _yggCopyTimer?.cancel();
                  _yggCopyTimer = Timer(const Duration(seconds: 2), () {
                    if (mounted && _copiedYggAddr) setState(() => _copiedYggAddr = false);
                  });
                },
        ),
      ],
    ]);
  }

  // 9. Опыты
  Widget _experimentsSection() => _section(_Section.experiments, _s.setExperiments, [
        _switch('refuseQuicOverStreams', _s.setRefuseQuic, divider: false),
        if (_api18) ...[
          _switch('honestConnect', _s.setHonestConnect, sub: _s.setHonestConnectSub),
          _switch('icmpThroughNode', _s.setIcmpThroughNode, sub: _s.setIcmpThroughNodeSub),
        ],
        _switch('icmpNoLocalReply', _s.setNoPingReply),
        _choice(
          'dpiDirect',
          _s.setDpiDirect,
          [('0', _s.setDpiOff), ('1', _s.setDpiPreset), ('2', _s.setDpiCustom)],
          cell: 96,
        ),
        if (_v.text('dpiDirect') == '1')
          _choice(
            'dpiDirectPreset',
            _s.setDpiPresetName,
            const [
              ('tlsrec_sni', 'TLS'),
              ('split_sni', 'Split'),
              ('disoob_sld', 'DisOOB'),
              ('disorder_1', 'Disorder'),
            ],
            cell: 84,
          ),
        if (_v.text('dpiDirect') == '2')
          _value(
            _s.setDpiCustomArgs,
            _v.text('dpiDirectCustom').isEmpty ? '—' : _v.text('dpiDirectCustom'),
            _Dialog(_s.setDpiCustomArgs, [('dpiDirectCustom', _s.setDpiCustomArgs, FieldInput.text)]),
          ),
        _switch('trafficSniffing', _s.setSniffing),
        _switch('resolveDestination', _s.setResolveDestination),
      ]);

  // 10. Журнал и вид
  Widget _logSection() => _section(_Section.log, _s.setLogView, [
        _choice('logLevel', _s.setLogLevel,
            [('0', 'none'), ('1', 'warn'), ('2', 'info'), ('3', 'debug'), ('4', 'trace')], cell: 64, divider: false),
        if (_api18)
          _value(
            _s.setGlobalCustomConfig,
            _v.text('globalCustomConfig').trim().isEmpty ? '—' : '{…}',
            _Dialog(
              _s.setGlobalCustomConfig,
              [('globalCustomConfig', _s.setGlobalCustomConfig, FieldInput.lines)],
              hint: _s.setGlobalCustomConfigHint,
            ),
          ),
      ]);

  // 11. Резервная копия
  Widget _backupSection() {
    final colors = NikoTheme.of(context);
    return _section(_Section.backup, _s.setBackupSection, [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: NikoSpace.s4, vertical: NikoSpace.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_s.setBackup, style: NikoType.body.style(colors.ink)),
            const SizedBox(height: 2),
            Text(_s.setBackupSub, style: NikoType.bodySm.style(colors.ink2)),
            const SizedBox(height: NikoSpace.s3),
            Wrap(
              spacing: NikoSpace.s2,
              runSpacing: NikoSpace.s2,
              children: [
                if (widget.onExportBackup != null)
                  NikoTonalButton(
                    label: _backupBusy ? _s.backupBusy : _s.backupExport,
                    onPressed: _backupBusy ? null : () => unawaited(_exportBackup()),
                  ),
                if (widget.onImportBackup != null)
                  NikoGhostButton(
                    label: _s.backupImport,
                    onPressed: _backupBusy ? null : () => unawaited(_importBackup()),
                  ),
                if (_api18)
                  NikoGhostButton(
                    label: _s.setResetSettings,
                    onPressed: _resetting ? null : () => setState(() => _confirmReset = true),
                  ),
              ],
            ),
            if (_confirmReset) ...[
              const SizedBox(height: NikoSpace.s3),
              NikoBanner(
                icon: NikoIcons.trash,
                title: _s.setResetConfirmTitle,
                text: _s.setResetConfirmText,
                danger: true,
              ),
              const SizedBox(height: NikoSpace.s2),
              Row(
                children: [
                  NikoPrimaryButton(
                    label: _s.setResetConfirmGo,
                    onPressed: _resetting ? null : () => unawaited(_resetSettings()),
                  ),
                  const SizedBox(width: NikoSpace.s3),
                  NikoGhostButton(
                    label: _s.cancel,
                    onPressed: () => setState(() => _confirmReset = false),
                  ),
                ],
              ),
            ],
            if (_backupMessage.isNotEmpty) ...[
              const SizedBox(height: NikoSpace.s2),
              Text(
                _backupMessage,
                style: NikoType.bodySm.style(_backupError ? colors.danger : colors.ink2),
              ),
            ],
          ],
        ),
      ),
    ]);
  }

  Widget _serviceRow(ServiceController svc) {
    final colors = NikoTheme.of(context);
    final installed = svc.mode == InstallMode.installed || svc.mode == InstallMode.portableServiceReady;
    final manualCmd = svc.lastActionWasUninstall ? svc.manualUninstallCommand : svc.manualCommand;
    final outcome = svc.lastOutcome;
    String statusMsg = '';
    var isDanger = false;
    if (outcome == InstallOutcome.ok && svc.lastActionWasUninstall) {
      statusMsg = _s.uninstallServiceDone;
    } else if (outcome == InstallOutcome.cancelled) {
      statusMsg = _s.installCancelled;
    } else if (outcome == InstallOutcome.polkitUnavailable) {
      statusMsg = manualCmd.isNotEmpty ? '${_s.installPolkitUnavailable}\n$manualCmd' : _s.installPolkitUnavailable;
      isDanger = true;
    } else if (outcome != null && outcome != InstallOutcome.ok) {
      statusMsg = svc.lastError.isNotEmpty ? '${_s.installFailed}: ${svc.lastError}' : _s.installFailed;
      isDanger = true;
    }
    return CustomPaint(
      foregroundPainter: _AboutHairline(colors.line),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NikoSpace.s4, vertical: NikoSpace.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s.setSystemService, style: NikoType.body.style(colors.ink)),
                      Text(
                        installed ? _s.serviceInstalledStatus : _s.serviceNotInstalledStatus,
                        style: NikoType.bodySm.style(colors.ink2),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: NikoSpace.s3),
                if (installed)
                  NikoGhostButton(
                    label: svc.uninstalling ? _s.uninstallingService : _s.uninstallService,
                    onPressed: svc.busy ? null : () => setState(() => _confirmUninstallService = true),
                  )
                else
                  NikoTonalButton(
                    label: svc.installing ? _s.installingService : _s.installService,
                    onPressed: svc.busy ? null : () => unawaited(svc.installService()),
                  ),
              ],
            ),
            if (_confirmUninstallService && installed) ...[
              const SizedBox(height: NikoSpace.s3),
              NikoBanner(
                icon: NikoIcons.trash,
                title: _s.uninstallServiceConfirmTitle,
                text: _s.uninstallServiceConfirmText,
                danger: true,
              ),
              const SizedBox(height: NikoSpace.s2),
              Row(
                children: [
                  NikoPrimaryButton(
                    label: svc.uninstalling ? _s.uninstallingService : _s.uninstallService,
                    onPressed: svc.busy
                        ? null
                        : () {
                            setState(() => _confirmUninstallService = false);
                            unawaited(svc.uninstallService());
                          },
                  ),
                  const SizedBox(width: NikoSpace.s3),
                  NikoGhostButton(
                    label: _s.cancel,
                    onPressed: () => setState(() => _confirmUninstallService = false),
                  ),
                ],
              ),
            ],
            if (statusMsg.isNotEmpty) ...[
              const SizedBox(height: NikoSpace.s3),
              NikoBanner(
                icon: isDanger ? NikoIcons.alert : NikoIcons.copy,
                title: statusMsg,
                danger: isDanger,
                action: outcome == InstallOutcome.polkitUnavailable && manualCmd.isNotEmpty ? _s.copyCommand : null,
                onAction: outcome == InstallOutcome.polkitUnavailable && manualCmd.isNotEmpty
                    ? () => unawaited(Clipboard.setData(ClipboardData(text: manualCmd)))
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _daemonSections() => [
        _raycontrolSection(),
        if (widget.advanced) _connectionSection(),
        _dnsSection(),
        if (widget.advanced) ...[
          _programsSection(),
          _inboundSection(),
          _naiveSection(),
          _yggdrasilSection(),
          _experimentsSection(),
          _logSection(),
        ],
        _backupSection(),
      ];

  // 12. О программе и обновления
  Widget _aboutSection(NikoColors colors, {required bool withDaemon}) => _section(_Section.about, _s.setAbout, [
        MergeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: NikoSpace.s4, vertical: NikoSpace.s3),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Niko $windowVersion', style: NikoType.body.style(colors.ink, weight: FontWeight.w600)),
                    if (widget.coreVersion.isNotEmpty)
                      Text('sing-box ${widget.coreVersion}', style: NikoType.code.style(colors.ink2)),
                    if (widget.nikoVersion.isNotEmpty && widget.nikoVersion != windowVersion)
                      Text('nikod ${widget.nikoVersion}', style: NikoType.code.style(colors.ink2)),
                  ],
                ),
              ),
            ),
          ),
        ),
        CustomPaint(
          foregroundPainter: _AboutHairline(colors.line),
          child: NikoInfoRow(title: _s.setUpdateKey, value: updateSigningKey),
        ),
        if (withDaemon && widget.advanced && _api18) _switch('includePrerelease', _s.setIncludePrerelease),
        if (widget.onCheckUpdate != null)
          CustomPaint(
            foregroundPainter: _AboutHairline(colors.line),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: NikoSpace.s4, vertical: NikoSpace.s3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: NikoSpace.s3,
                    runSpacing: NikoSpace.s2,
                    children: [
                      NikoTonalButton(
                        label: _checkingUpdate ? _s.updateChecking : _s.updateCheck,
                        onPressed: _checkingUpdate || _downloadingUpdate ? null : () => unawaited(_checkUpdate()),
                      ),
                      if (_updateInfo != null &&
                          _updateInfo!.updateAvailable &&
                          widget.onDownloadUpdate != null)
                        NikoPrimaryButton(
                          label: _downloadingUpdate ? _s.updateDownloading : _s.updateDownload,
                          onPressed: _downloadingUpdate ? null : () => unawaited(_downloadUpdate(_updateInfo!.tag)),
                        ),
                    ],
                  ),
                  if (_updateError.isNotEmpty) ...[
                    const SizedBox(height: NikoSpace.s3),
                    NikoBanner(icon: NikoIcons.alert, title: _s.errorTitle, text: _updateError, danger: true),
                  ] else if (_updateDownload case final dl?) ...[
                    const SizedBox(height: NikoSpace.s3),
                    NikoBanner(
                      icon: NikoIcons.copy,
                      title: _s.updateVerifiedBadge,
                      text: _s.updateDownloaded(dl.filePath, dl.sha256),
                    ),
                  ] else if (_updateInfo case final info?) ...[
                    const SizedBox(height: NikoSpace.s3),
                    NikoBanner(
                      icon: NikoIcons.rotateCw,
                      title: info.updateAvailable
                          ? _s.updateAvailable(info.latestVersion, info.source.isEmpty ? 'github' : info.source)
                          : _s.updateUpToDate,
                      text: [
                        if (info.verified)
                          _s.updateVerifiedBadge
                        else if (info.updateAvailable)
                          _s.updateUnverifiedMirror,
                        if (info.assetName.isNotEmpty) info.assetName,
                        if (info.notes.isNotEmpty) info.notes,
                      ].join('\n'),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ]);

  // 13. Справка
  Widget _helpSection() => _section(_Section.help, _s.setHelpSection, [
        NikoLinkRow(
          title: _s.setHelpValues,
          value: '',
          divider: false,
          onPressed: widget.onOpenFaq ?? () {},
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final hasDaemon = widget.notice == null;
    final menuSections = <_Section>[
      _Section.general,
      if (hasDaemon) ...[
        _Section.raycontrol,
        if (widget.advanced) _Section.connection,
        _Section.dns,
        if (widget.advanced) ...[
          _Section.programs,
          _Section.inbound,
          _Section.naive,
          _Section.yggdrasil,
          _Section.experiments,
          _Section.log,
        ],
        _Section.backup,
      ],
      _Section.about,
      if (widget.onOpenFaq != null) _Section.help,
    ];
    return ColoredBox(
      color: colors.surface0,
      child: ListenableBuilder(
        listenable: Listenable.merge([_v, _window, ?widget.serviceInstall]),
        builder: (context, _) => Stack(
          children: [
            ExcludeSemantics(
              excluding: _dialog != null,
              child: ExcludeFocus(
                excluding: _dialog != null,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 840;
                    final content = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Semantics(header: true, child: Text(_s.sectionSettings, style: NikoType.title.style(colors.ink))),
                        if (hasDaemon && _v.error.isNotEmpty) ...[
                          const SizedBox(height: NikoSpace.s6),
                          NikoBanner(icon: NikoIcons.alert, title: _s.settingsNotKept, text: _v.error, danger: true),
                        ],
                        const SizedBox(height: NikoSpace.s8),
                        _generalSection(withDaemon: hasDaemon),
                        if (widget.notice case (final title, final text)) ...[
                          if (title.isNotEmpty) ...[
                            const SizedBox(height: NikoSpace.s6),
                            NikoBanner(icon: NikoIcons.alert, title: title, text: text),
                          ],
                        ] else ...[
                          for (final section in _daemonSections()) ...[const SizedBox(height: NikoSpace.s8), section],
                        ],
                        const SizedBox(height: NikoSpace.s8),
                        _aboutSection(colors, withDaemon: hasDaemon),
                        if (widget.onOpenFaq != null) ...[
                          const SizedBox(height: NikoSpace.s8),
                          _helpSection(),
                        ],
                      ],
                    );
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (wide)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(start: NikoSpace.s8, top: NikoSpace.s4),
                            child: SizedBox(
                              width: 220,
                              child: SingleChildScrollView(
                                child: Semantics(
                                  container: true,
                                  explicitChildNodes: true,
                                  label: _s.settingsMenu,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      for (final section in menuSections)
                                        _MenuItem(
                                          name: _name(section),
                                          active: section == _current ||
                                              !menuSections.contains(_current) && section == _Section.general,
                                          onPressed: () => _jump(section),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: _scroll,
                            padding: EdgeInsets.fromLTRB(wide ? NikoSpace.s8 : NikoSpace.s5, NikoSpace.s4,
                                wide ? NikoSpace.s8 : NikoSpace.s5, 48),
                            child: Align(
                              alignment: AlignmentDirectional.topStart,
                              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: content),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            if (_dialog case final dialog?)
              if (dialog.language)
                _LanguageDialog(
                  key: const ValueKey('language'),
                  initial: _window.language,
                  strings: _s,
                  onSave: (lang) {
                    _window.language = lang;
                    unawaited(_window.save());
                    widget.onLanguage?.call(lang);
                    _closeDialog();
                  },
                  onClose: _closeDialog,
                )
              else
                _ValueDialog(
                  key: ValueKey(dialog.title),
                  dialog: dialog,
                  values: _v,
                  strings: _s,
                  strategy: _strategy,
                  onClose: _closeDialog,
                ),
          ],
        ),
      ),
    );
  }
}

/// A section's name in the settings' menu (n-menu > n-nav__item): quiet, in ink and heavier for the one chosen.
class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.name, required this.active, required this.onPressed});

  final String name;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    return Semantics(
      container: true,
      button: true,
      selected: active,
      child: NikoPressable(
        onPressed: onPressed,
        radius: NikoRadius.sm,
        builder: (context, state) => DecoratedBox(
          decoration: BoxDecoration(
            color: state.pressed ? colors.surface2 : null,
            borderRadius: BorderRadius.circular(NikoRadius.sm),
          ),
          child: SizedBox(
            height: NikoSize.tap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: NikoSpace.s4),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NikoType.body.style(
                    active || state.hovered ? colors.ink : colors.ink2,
                    weight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The dialog of a value row (m-dialog): its fields with what the daemon has, Отмена and Сохранить; what the daemon
/// refused said under them, the dialog left open. Escape closes it.
class _ValueDialog extends StatefulWidget {
  const _ValueDialog({
    super.key,
    required this.dialog,
    required this.values,
    required this.strings,
    required this.strategy,
    required this.onClose,
  });

  final _Dialog dialog;
  final SettingValues values;
  final NikoStrings strings;
  final String Function(String key) strategy;
  final VoidCallback onClose;

  @override
  State<_ValueDialog> createState() => _ValueDialogState();
}

class _ValueDialogState extends State<_ValueDialog> {
  late final Map<String, String> _texts = {
    for (final (key, _, _) in widget.dialog.fields) key: widget.values.text(key),
    if (widget.dialog.strategies)
      for (final key in _strategyKeys) key: widget.strategy(key),
  };
  String _error = '';
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final error = await widget.values.save(texts: _texts);
    if (!mounted) return;
    if (error == null) {
      widget.onClose();
      return;
    }
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final s = widget.strings;
    final dialog = widget.dialog;
    return NikoDialog(
      title: dialog.title,
      maxWidth: dialog.strategies ? 640 : 480,
      cancelLabel: s.cancel,
      saveLabel: s.save,
      errorTitle: s.settingsNotKept,
      error: _error,
      onClose: widget.onClose,
      onSave: _saving ? null : _save,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (key, label, input) in dialog.fields) ...[
            NikoField(
              label: label,
              value: _texts[key]!,
              input: input,
              mono: true,
              onChanged: (v) => _texts[key] = v,
            ),
            const SizedBox(height: NikoSpace.s4),
          ],
          if (dialog.strategies)
            for (final (key, label) in [
              (_strategyKeys[0], s.setStrategyRemote),
              (_strategyKeys[1], s.setStrategyDirect),
              (_strategyKeys[2], s.setStrategyServer),
            ]) ...[
              ExcludeSemantics(child: Text(label, style: NikoType.caption.style(colors.ink2))),
              const SizedBox(height: NikoSpace.s2),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: NikoSegmented<String>(
                  label: label,
                  choices: [for (final v in _strategies) (v, s.strategy(v))],
                  value: _texts[key]!,
                  onChanged: (v) => setState(() => _texts[key] = v),
                  cell: 96,
                ),
              ),
              const SizedBox(height: NikoSpace.s4),
            ],
          if (dialog.hint.isNotEmpty) ...[
            Text(dialog.hint, style: NikoType.bodySm.style(colors.ink2)),
            const SizedBox(height: NikoSpace.s4),
          ],
        ],
      ),
    );
  }
}

/// The language choice dialog (D-SET-13): system, Русский or English, each named in its own language.
class _LanguageDialog extends StatefulWidget {
  const _LanguageDialog({
    super.key,
    required this.initial,
    required this.strings,
    required this.onSave,
    required this.onClose,
  });

  final String initial;
  final NikoStrings strings;
  final ValueChanged<String> onSave;
  final VoidCallback onClose;

  @override
  State<_LanguageDialog> createState() => _LanguageDialogState();
}

class _LanguageDialogState extends State<_LanguageDialog> {
  late String _choice = widget.initial;

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    return NikoDialog(
      title: s.setLanguage,
      maxWidth: 520,
      cancelLabel: s.cancel,
      saveLabel: s.save,
      onClose: widget.onClose,
      onSave: () => widget.onSave(_choice),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: NikoSegmented<String>(
              label: s.setLanguage,
              choices: [('system', s.langSystem), ('ru', 'Русский'), ('en', 'English')],
              value: _choice,
              onChanged: (value) => setState(() => _choice = value),
              cell: 136,
            ),
          ),
          const SizedBox(height: NikoSpace.s5),
        ],
      ),
    );
  }
}

class _AboutHairline extends CustomPainter {
  _AboutHairline(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawRect(Rect.fromLTWH(NikoSpace.s4, 0, size.width - NikoSpace.s4, NikoStroke.hairline), Paint()..color = color);

  @override
  bool shouldRepaint(_AboutHairline oldDelegate) => color != oldDelegate.color;
}
