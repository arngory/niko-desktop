import 'dart:async';

import 'package:flutter/widgets.dart';

import '../l10n/strings.dart';
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

/// Настройки (B-Settings), made by hand on the settings components: the window's own choices (theme, language —
/// always available) and the computer's settings the daemon's build takes (NikoService.GetSettings), each kept as it is
/// changed. A value row opens a dialog; the dialog keeps what the daemon took, or says why not.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.values,
    required this.strings,
    this.window,
    this.onLanguage,
    this.notice,
  });

  /// The settings by the app's names (SettingsFeed: the daemon's).
  final SettingValues values;
  final NikoStrings strings;

  /// The window's own remembered choices (theme, language); null: kept in memory.
  final WindowSettings? window;

  /// Called after the user saves a language choice, so the shell can inform the daemon.
  final ValueChanged<String>? onLanguage;

  /// What is shown in place of the daemon's sections, a title and what to know under it: no link to the daemon, the
  /// settings not read; an empty title: nothing yet (they are being read); null: the daemon's sections are shown.
  final (String, String)? notice;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// The sections, in the canvas's order.
enum _Section { general, connection, dns, programs, inbound, experiments, log }

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

  WindowSettings get _window => widget.window ?? (_ownedWindow ??= WindowSettings.memory());

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
        _Section.connection => _s.setConnection,
        _Section.dns => _s.setDns,
        _Section.programs => _s.setPrograms,
        _Section.inbound => _s.setInboundMenu,
        _Section.experiments => _s.setExperiments,
        _Section.log => _s.setLog,
      };

  void _jump(_Section section) {
    setState(() => _current = section);
    final target = _keys[section]!.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  // an unset strategy is the app's "auto" as its menu shows it
  String _strategy(String key) => _v.text(key).isEmpty ? 'auto' : _v.text(key);

  String _strategySummary() {
    final values = {for (final key in _strategyKeys) _strategy(key)};
    return values.length == 1 ? _s.strategy(values.single) : _s.setStrategyMixed;
  }

  // a DNS setting's servers, a line each ("#" a comment), as the phone's list shows them: the first one's host
  // (https://cloudflare-dns.com/dns-query as cloudflare-dns.com), and +1, +2 for the ones the core asks after it
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

  // the programs chosen: each line that names one, once
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

  Widget _generalSection({required bool withDaemon}) => _section(_Section.general, _s.setGeneral, [
        // D-SET-03
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
        // D-SET-13
        NikoLinkRow(
          title: _s.setLanguage,
          value: _languageName(_window.language),
          divider: true,
          onPressed: () => _openDialog(_Dialog(_s.setLanguage, const [], language: true)),
        ),
        if (withDaemon) ...[
          _choice('serviceMode', _s.setMode, [('vpn', _s.setModeVpn), ('proxy', _s.setModeProxy)], cell: 96),
          _switch('systemProxy', _s.setSystemProxy, sub: _s.setSystemProxySub),
        ],
      ]);

  List<Widget> _daemonSections() => [
        _section(_Section.connection, _s.setConnection, [
          _choice('tunImplementation', _s.setTun, [('0', 'gVisor'), ('1', 'System'), ('2', 'Mixed')], cell: 88,
              divider: false),
          _value(_s.setMtu, _v.text('mtu'), _Dialog(_s.setMtu, [('mtu', _s.setMtu, FieldInput.port)], hint: _s.setMtuHint)),
          _choice('ipv6Mode', _s.setIpv6,
              [('0', _s.setIpv6Off), ('1', _s.setIpv6On), ('2', _s.setIpv6Prefer), ('3', _s.setIpv6Only)], cell: 84),
          _switch('globalAllowInsecure', _s.setInsecure, sub: _s.setDangerous),
        ]),
        _section(_Section.dns, _s.setDns, [
          _value(_s.setRemoteDns, _dnsServers('remoteDns'),
              _Dialog(_s.setRemoteDns, [('remoteDns', _s.setRemoteDns, FieldInput.lines)], hint: _s.setRemoteDnsHint),
              divider: false),
          _value(_s.setDirectDns, _v.text('directDns').split('\n').first,
              _Dialog(_s.setDirectDns, [('directDns', _s.setDirectDns, FieldInput.text)], hint: _s.setDnsHint)),
          _switch('enableFakeDns', _s.setFakeIp, sub: _s.setInVpn),
          _value(_s.setStrategy, _strategySummary(), _Dialog(_s.setStrategy, const [], strategies: true), mono: false),
          _switch('dnsOptimisticCache', _s.setOptimisticCache),
          _switch('bypassLanInCore', _s.setLanDirect),
        ]),
        // D-RULES-06: as the phone's apps through the VPN, a rule by program ahead of the rules (D-RULES-02)
        _section(_Section.programs, _s.setPrograms, [
          _choice('programsMode', _s.setProgramsThrough,
              [('0', _s.setProgramsAll), ('1', _s.setProgramsOnly), ('2', _s.setProgramsExcept)], cell: 148,
              divider: false),
          _value(
            _s.setProgramsList,
            _programs(),
            _Dialog(_s.setProgramsList, [('programs', _s.setProgramsList, FieldInput.lines)], hint: _s.setProgramsHint),
            mono: false,
          ),
        ]),
        _section(_Section.inbound, _s.setInbound, [
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
        ]),
        _section(_Section.experiments, _s.setExperiments, [
          _switch('refuseQuicOverStreams', _s.setRefuseQuic, divider: false),
          _switch('icmpNoLocalReply', _s.setNoPingReply),
          _switch('trafficSniffing', _s.setSniffing),
          _switch('resolveDestination', _s.setResolveDestination),
        ]),
        _section(_Section.log, _s.setLog, [
          _choice('logLevel', _s.setLogLevel,
              [('0', 'none'), ('1', 'warn'), ('2', 'info'), ('3', 'debug'), ('4', 'trace')], cell: 64, divider: false),
        ]),
      ];

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final hasDaemon = widget.notice == null;
    final menuSections = hasDaemon ? _Section.values : const [_Section.general];
    return ColoredBox(
      color: colors.surface0,
      child: ListenableBuilder(
        listenable: Listenable.merge([_v, _window]),
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
                                        active: section == _current || !menuSections.contains(_current) && section == _Section.general,
                                        onPressed: () => _jump(section),
                                      ),
                                  ],
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
