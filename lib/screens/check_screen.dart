import 'package:flutter/widgets.dart';

import '../daemon/daemon.dart';
import '../l10n/strings.dart';
import '../state/connection_controller.dart';
import '../state/profiles_feed.dart';
import '../state/route_check.dart';
import '../state/rules_feed.dart';
import '../state/window_settings.dart';
import '../theme/niko_theme.dart';
import '../ui/banner.dart';
import '../ui/controls.dart';
import '../ui/format.dart';
import '../ui/header.dart';
import '../ui/icons.dart';
import '../ui/list.dart';
import '../ui/pressable.dart';
import 'nodes_screen.dart' show groupName, typeLabel;

/// Проверка маршрута (B-Check, D-CHECK-02…07): tests which rule and outbound of the running core a destination
/// would match, explains why, shows rule-set freshness, and remembers recent successful checks.
class CheckScreen extends StatefulWidget {
  const CheckScreen({
    super.key,
    required this.check,
    required this.controller,
    required this.profiles,
    required this.rules,
    required this.vpnMode,
    required this.advanced,
    this.now = DateTime.now,
  });

  final RouteCheckController check;
  final ConnectionController controller;
  final ProfilesFeed profiles;
  final RulesFeed rules;
  final bool vpnMode;
  final bool advanced;
  final DateTime Function() now;

  @override
  State<CheckScreen> createState() => _CheckScreenState();
}

class _CheckScreenState extends State<CheckScreen> {
  late final TextEditingController _target = TextEditingController(text: widget.check.target);

  @override
  void initState() {
    super.initState();
    _target.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(CheckScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.check.target != _target.text) {
      _target.value = TextEditingValue(
        text: widget.check.target,
        selection: TextSelection.collapsed(offset: widget.check.target.length),
      );
    }
  }

  void _onTextChanged() {
    widget.check.setTarget(_target.text);
  }

  @override
  void dispose() {
    _target.removeListener(_onTextChanged);
    _target.dispose();
    super.dispose();
  }

  bool get _readyToCheck =>
      widget.controller.link == LinkPhase.ready &&
      widget.controller.nikoApi > 0 &&
      widget.controller.service.phase == ServicePhase.started;

  void _run(NikoStrings strings) {
    if (!_readyToCheck || widget.check.busy || parseRouteTarget(widget.check.target) == null) return;
    widget.check.check(
      vpnMode: widget.vpnMode,
      describeOutcome: (verdict) => _describeOutcome(verdict, strings),
    );
  }

  void _replay(RecentRouteCheck entry, NikoStrings strings) {
    _target.value = TextEditingValue(
      text: entry.target,
      selection: TextSelection.collapsed(offset: entry.target.length),
    );
    widget.check.setTarget(entry.target);
    widget.check.setNetwork(entry.network);
    if (_readyToCheck && !widget.check.busy) _run(strings);
  }

  /// Extracts `srs:` rule-set tags named in a rule's domains and IP lists.
  static List<String> _srsItems(RuleRow rule) => [
        for (final raw in '${rule.domains}\n${rule.ip}'.split('\n'))
          if (raw.trim().startsWith('srs:')) raw.trim(),
      ];

  /// Splits the core's matched rule string into exact tokens so `srs:` tags never match by substring prefix.
  static Set<String> _ruleTokens(String ruleText) => {
        for (final token in ruleText.split(RegExp(r'[\s\[\],=]+')))
          if (token.isNotEmpty) token,
      };

  static bool _matchesOutbound(RuleRow rule, RouteVerdict verdict) {
    final isBlock = verdict.action == 'reject' || verdict.outbound == 'block';
    if (isBlock) return rule.outbound == RuleOutbound.block;
    if (verdict.outbound == 'direct') return rule.outbound == RuleOutbound.direct;
    return rule.outbound == RuleOutbound.proxy || rule.outbound > 0;
  }

  /// Matches the core's matched rule string against enabled stored [RuleRow]s by exact `srs:` token and outbound.
  RuleRow? _matchedRule(RouteVerdict verdict) {
    if (verdict.index < 0 || verdict.rule.isEmpty) return null;
    final tokens = _ruleTokens(verdict.rule);
    for (final rule in widget.rules.rules) {
      if (!rule.enabled || !_matchesOutbound(rule, verdict)) continue;
      for (final item in _srsItems(rule)) {
        if (tokens.contains(item)) return rule;
      }
    }
    return null;
  }

  /// Selected profile's group name and type label (e.g. `arngory · naive`), or null if unknown.
  String? _proxyLabel(NikoStrings strings, {bool withType = true}) {
    final profile = widget.profiles.selectedProfile;
    final group = widget.profiles.groups.where((g) => g.id == widget.profiles.selectedGroup).firstOrNull;
    final gName = group != null ? groupName(group, strings) : null;
    if (gName != null && profile != null && withType) {
      return '$gName · ${typeLabel(profile.type)}';
    }
    if (gName != null) return gName;
    if (profile != null) return withType ? typeLabel(profile.type) : profile.name;
    return null;
  }

  (String outcome, String label) _describeOutcome(RouteVerdict verdict, NikoStrings strings) {
    if (verdict.action == 'reject' || verdict.outbound == 'block') {
      return ('block', strings.routeBlock);
    }
    if (verdict.outbound == 'direct') {
      return ('direct', strings.routeDirect);
    }
    final shortProxy = _proxyLabel(strings, withType: false) ??
        (verdict.outbound.isNotEmpty ? verdict.outbound : strings.routeProxy);
    return ('proxy', shortProxy);
  }

  String _outboundTagLabel(RouteVerdict verdict, NikoStrings strings) {
    if (verdict.action == 'reject' || verdict.outbound == 'block') return strings.routeBlock;
    if (verdict.outbound == 'direct') return strings.routeDirect;
    return _proxyLabel(strings, withType: true) ??
        (verdict.outbound.isNotEmpty ? verdict.outbound : strings.routeProxy);
  }

  String _ruleTagLabel(RouteVerdict verdict, RuleRow? matched, NikoStrings strings) {
    if (verdict.index < 0) return strings.checkRuleFinal;
    if (matched != null && matched.name.isNotEmpty) return matched.name;
    return strings.ruleDisplayName(verdict.index + 1);
  }

  /// Enabled direct rules that reference at least one `srs:` rule-set.
  List<RuleRow> _directSrsRules() => [
        for (final r in widget.rules.rules)
          if (r.enabled && r.outbound == RuleOutbound.direct && _srsItems(r).isNotEmpty) r,
      ];

  String _answerLine(RouteVerdict verdict, RuleRow? matched, List<RuleRow> directSrs, NikoStrings strings) {
    final isBlock = verdict.action == 'reject' || verdict.outbound == 'block';
    final isDirect = verdict.outbound == 'direct';
    if (verdict.index >= 0) {
      final name = _ruleTagLabel(verdict, matched, strings);
      if (isBlock) return strings.checkAnswerBlock(name);
      if (isDirect) return strings.checkAnswerDirect(name);
      return strings.checkAnswerProxyRule(name);
    }
    if (isBlock) return strings.routeBlock;
    if (isDirect) return strings.routeDirect;
    if (directSrs.isNotEmpty) {
      final names = [for (final r in directSrs) r.name.isNotEmpty ? r.name : strings.ruleDisplayName(r.id)].join(', ');
      return strings.checkAnswerProxyNotIn(names);
    }
    return strings.checkAnswerProxy;
  }

  String? _freshnessCaption(
    RouteVerdict verdict,
    RuleRow? matched,
    List<RuleRow> directSrs,
    NikoStrings strings,
  ) {
    final List<RuleRow> relevantRules;
    final Set<String> itemSet;
    if (verdict.index >= 0) {
      final tokens = _ruleTokens(verdict.rule);
      final matchedItems = matched == null
          ? const <String>[]
          : [for (final item in _srsItems(matched)) if (tokens.contains(item)) item];
      if (matched == null || matchedItems.isEmpty) return null;
      relevantRules = [matched];
      itemSet = matchedItems.toSet();
    } else if (verdict.action != 'reject' && verdict.outbound != 'block' && verdict.outbound != 'direct') {
      if (directSrs.isEmpty) return null;
      relevantRules = directSrs;
      itemSet = {for (final r in directSrs) ..._srsItems(r)};
    } else {
      return null;
    }

    final label = [for (final r in relevantRules) r.name.isNotEmpty ? r.name : strings.ruleDisplayName(r.id)].join(', ');
    final rows = [
      for (final rs in widget.rules.ruleSets.ruleSets)
        if (itemSet.contains(rs.item)) rs,
    ];
    if (rows.isEmpty || rows.any((rs) => !rs.downloaded || rs.updated <= 0)) {
      return strings.checkRuleSetNotFetched(label);
    }
    var oldest = rows.first.updated;
    for (final rs in rows.skip(1)) {
      if (rs.updated < oldest) oldest = rs.updated;
    }
    final when = formatRecent(
      DateTime.fromMillisecondsSinceEpoch(oldest * 1000),
      widget.now(),
      today: strings.today,
      yesterday: strings.yesterday,
    );
    return strings.checkRuleSetUpdated(label, when);
  }

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final strings = NikoStrings.of(Localizations.localeOf(context));
    final state = widget.check;
    final ctrl = widget.controller;
    final parsed = parseRouteTarget(state.target);
    final canPress = _readyToCheck && !state.busy && parsed != null;

    Widget? statusBanner;
    if (ctrl.link != LinkPhase.ready) {
      statusBanner = NikoBanner(icon: NikoIcons.alert, title: strings.storeNoLink);
    } else if (ctrl.nikoApi == 0) {
      statusBanner = NikoBanner(icon: NikoIcons.alert, title: strings.checkNeedsNiko);
    } else if (ctrl.service.phase != ServicePhase.started) {
      statusBanner = NikoBanner(icon: NikoIcons.alert, title: strings.connectionsIdle);
    } else if (state.error.isNotEmpty) {
      statusBanner = NikoBanner(icon: NikoIcons.alert, title: strings.checkFailed, text: state.error, danger: true);
    }

    final verdict = state.verdict;
    final checkedTarget = state.checkedTarget;
    final matched = verdict != null ? _matchedRule(verdict) : null;
    final directSrs = verdict != null ? _directSrsRules() : const <RuleRow>[];
    final isProxy = verdict != null &&
        verdict.action != 'reject' &&
        verdict.outbound != 'block' &&
        verdict.outbound != 'direct';
    final caption = verdict != null ? _freshnessCaption(verdict, matched, directSrs, strings) : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final pad = constraints.maxWidth < NikoHeader.narrow ? NikoSpace.s4 : NikoSpace.s8;
        final colWidth = (constraints.maxWidth - 2 * pad).clamp(0.0, 760.0);
        // field grows to fill the row alongside the TCP/UDP switch and Check button, min 280 when room allows
        final fieldMin = colWidth >= 280 ? 280.0 : colWidth;
        final inlineControlsWidth = 156.0 + 140.0 + 2 * NikoSpace.s3;
        final fieldWidth = colWidth >= fieldMin + inlineControlsWidth
            ? colWidth - inlineControlsWidth
            : colWidth;

        return SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760 + 2 * NikoSpace.s8),
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad, NikoSpace.s8, pad, 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(header: true, child: Text(strings.sectionCheck, style: NikoType.title.style(colors.ink))),
                    const SizedBox(height: NikoSpace.s6),
                    // D-CHECK-02, -03
                    Wrap(
                      spacing: NikoSpace.s3,
                      runSpacing: NikoSpace.s3,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: fieldWidth,
                          child: NikoTextField(
                            label: strings.checkAddress,
                            labelHidden: true,
                            placeholder: 'youtube.com',
                            fill: colors.surface2,
                            controller: _target,
                            onSubmit: (_) => _run(strings),
                          ),
                        ),
                        NikoSegmented<String>(
                          label: strings.checkProtocol,
                          choices: const [('tcp', 'TCP'), ('udp', 'UDP')],
                          value: state.network,
                          onChanged: state.busy ? (_) {} : state.setNetwork,
                          cell: 72,
                        ),
                        NikoPrimaryButton(
                          label: state.busy ? strings.checkChecking : strings.checkButton,
                          onPressed: canPress ? () => _run(strings) : null,
                        ),
                      ],
                    ),
                    if (statusBanner != null) ...[
                      const SizedBox(height: NikoSpace.s6),
                      statusBanner,
                    ],
                    if (verdict != null && checkedTarget != null) ...[
                      const SizedBox(height: NikoSpace.s6),
                      // D-CHECK-04…06
                      Semantics(
                        container: true,
                        label: strings.checkResult,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surface1,
                            borderRadius: BorderRadius.circular(NikoRadius.md),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(NikoSpace.s6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Wrap(
                                  spacing: NikoSpace.s2,
                                  runSpacing: NikoSpace.s2,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    NikoTag(checkedTarget.display, strong: true, large: true),
                                    NikoIcon(NikoIcons.chevronRight, size: 20, color: colors.ink2),
                                    NikoTag(_ruleTagLabel(verdict, matched, strings), large: true),
                                    NikoIcon(NikoIcons.chevronRight, size: 20, color: colors.ink2),
                                    NikoTag(_outboundTagLabel(verdict, strings), strong: isProxy, large: true),
                                  ],
                                ),
                                const SizedBox(height: NikoSpace.s4),
                                Text(
                                  _answerLine(verdict, matched, directSrs, strings),
                                  style: NikoType.body.style(colors.ink),
                                ),
                                if (caption != null) ...[
                                  const SizedBox(height: NikoSpace.s4),
                                  Text(caption, style: NikoType.caption.style(colors.ink2)),
                                ],
                                if (verdict.error.isNotEmpty) ...[
                                  const SizedBox(height: NikoSpace.s4),
                                  NikoBanner(
                                    icon: NikoIcons.alert,
                                    title: strings.checkNoRoute,
                                    text: verdict.error,
                                    danger: true,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (widget.advanced && verdict.steps.isNotEmpty) ...[
                        const SizedBox(height: NikoSpace.s6),
                        NikoSection(
                          overline: strings.checkSteps,
                          rows: [
                            for (final step in verdict.steps)
                              NikoTextRow(
                                title: step.index >= 0
                                    ? '${strings.ruleDisplayName(step.index + 1)} · ${step.action}'
                                    : step.action,
                                sub: [
                                  if (step.rule.isNotEmpty) step.rule,
                                  if (step.resolved.isNotEmpty) step.resolved.join(', '),
                                  if (step.note.isNotEmpty) step.note,
                                ].join(' · '),
                                mono: true,
                              ),
                          ],
                        ),
                      ],
                      if (widget.advanced && verdict.notes.isNotEmpty) ...[
                        const SizedBox(height: NikoSpace.s6),
                        NikoSection(
                          overline: strings.checkNotes,
                          rows: [for (final note in verdict.notes) NikoTextRow(title: note, sub: '')],
                        ),
                      ],
                    ],
                    // D-CHECK-07
                    if (state.recent.isNotEmpty) ...[
                      const SizedBox(height: NikoSpace.s6),
                      NikoSection(
                        overline: strings.checkRecent,
                        action: NikoIconButton(
                          icon: NikoIcons.trash,
                          label: strings.checkClearRecent,
                          muted: true,
                          small: true,
                          onPressed: state.clearRecent,
                        ),
                        rows: [
                          for (final (i, entry) in state.recent.indexed)
                            _RecentRow(
                              entry: entry,
                              strings: strings,
                              divider: i > 0,
                              onPressed: () => _replay(entry, strings),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.entry, required this.strings, required this.divider, required this.onPressed});

  final RecentRouteCheck entry;
  final NikoStrings strings;
  final bool divider;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final display = entry.network == 'udp' ? '${entry.target} · UDP' : entry.target;
    final tagLabel = switch (entry.outcome) {
      'direct' => strings.routeDirect,
      'block' => strings.routeBlock,
      _ => entry.label,
    };
    return Semantics(
      button: true,
      label: '$display, $tagLabel',
      excludeSemantics: true,
      child: NikoPressable(
        radius: 0,
        onPressed: onPressed,
        builder: (context, state) => CustomPaint(
          foregroundPainter: divider ? _RowHairline(colors.line) : null,
          child: ColoredBox(
            color: state.pressed ? colors.surface2 : const Color(0x00000000),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: NikoSpace.s4, vertical: NikoSpace.s3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        display,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NikoType.code.style(colors.ink),
                      ),
                    ),
                    const SizedBox(width: NikoSpace.s3),
                    NikoTag(tagLabel, strong: entry.outcome == 'proxy'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RowHairline extends CustomPainter {
  _RowHairline(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawRect(Rect.fromLTWH(NikoSpace.s4, 0, size.width - NikoSpace.s4, NikoStroke.hairline), Paint()..color = color);

  @override
  bool shouldRepaint(_RowHairline oldDelegate) => color != oldDelegate.color;
}
