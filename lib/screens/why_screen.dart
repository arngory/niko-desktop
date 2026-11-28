import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';

import '../daemon/daemon.dart';
import '../l10n/strings.dart';
import '../platform/places.dart' as places;
import '../theme/niko_theme.dart';
import '../ui/banner.dart';
import '../ui/controls.dart';
import '../ui/icons.dart';
import '../ui/list.dart';

/// "Why isn't it working?" diagnostic runner for a raycontrol node (D-WHY).
/// Streams live steps from NikoService.RunNodeTest, displays structured findings,
/// and lets the user copy or save the redacted diagnostic report.
class WhyScreen extends StatefulWidget {
  const WhyScreen({
    super.key,
    required this.daemon,
    required this.node,
    required this.onBack,
    this.saveTo,
    this.now = DateTime.now,
    this.onSwitchToName,
  });

  final Daemon daemon;
  final NodeRow node;
  final VoidCallback onBack;
  final Directory? Function()? saveTo;
  final DateTime Function() now;

  /// Optional callback invoked when the user clicks the top recommendation to switch to a working profile.
  final ValueChanged<String>? onSwitchToName;

  @override
  State<WhyScreen> createState() => _WhyScreenState();
}

class _WhyScreenState extends State<WhyScreen> {
  late final TextEditingController _runId;
  StreamSubscription<NodeTestEvent>? _sub;
  final List<NodeTestEvent> _events = [];
  bool _running = false;
  String _error = '';
  NodeTestFindings? _findings;
  String _reportName = '';
  String _reportText = '';
  String _notice = '';

  @override
  void initState() {
    super.initState();
    final utc = widget.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final def = 'r-${utc.year}${two(utc.month)}${two(utc.day)}-${two(utc.hour)}${two(utc.minute)}';
    _runId = TextEditingController(text: def);
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _runId.dispose();
    super.dispose();
  }

  void _start() {
    if (_running) return;
    unawaited(_sub?.cancel());
    setState(() {
      _running = true;
      _error = '';
      _notice = '';
      _events.clear();
      _findings = null;
      _reportName = '';
      _reportText = '';
    });
    _sub = widget.daemon.runNodeTest(widget.node.id, runId: _runId.text.trim()).listen(
      (ev) {
        if (!mounted) return;
        setState(() {
          _events.add(ev);
          if (ev.error.isNotEmpty) _error = ev.error;
          if (ev.findings != null) _findings = ev.findings;
          if (ev.reportName.isNotEmpty) _reportName = ev.reportName;
          if (ev.reportText.isNotEmpty) _reportText = ev.reportText;
          if (ev.done) _running = false;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _running = false;
          _error = daemonError(e);
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _running = false);
      },
      cancelOnError: true,
    );
  }

  Future<void> _copyReport(NikoStrings strings) async {
    if (_reportText.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _reportText));
    if (mounted) setState(() => _notice = strings.whyReportCopied);
  }

  Future<void> _saveReport(NikoStrings strings) async {
    if (_reportText.isEmpty) return;
    try {
      final dir = (widget.saveTo ?? places.saveDirectory)();
      if (dir == null) throw StateError('no save directory');
      dir.createSync(recursive: true);
      final name = _reportName.isNotEmpty ? _reportName : 'niko-diagnostic.log';
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      file.writeAsStringSync(_reportText, flush: true);
      if (mounted) setState(() => _notice = strings.whyReportSaved(file.path));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final strings = NikoStrings.of(Localizations.localeOf(context));
    final findings = _findings;
    final working = findings?.profiles.where((p) => p.works).toList() ?? const <NodeTestProfile>[];
    final failing = findings?.profiles.where((p) => !p.works).toList() ?? const <NodeTestProfile>[];

    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(NikoSpace.s8, NikoSpace.s6, NikoSpace.s8, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    NikoGhostButton(label: strings.whyBack, onPressed: widget.onBack),
                    const SizedBox(width: NikoSpace.s3),
                    Expanded(
                      child: Text(
                        '${strings.whyTitle} · ${widget.node.name}',
                        style: NikoType.title.style(colors.ink),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: NikoSpace.s5),
                NikoTextField(
                  controller: _runId,
                  label: strings.whyRunId,
                ),
                const SizedBox(height: NikoSpace.s3),
                Wrap(
                  spacing: NikoSpace.s3,
                  runSpacing: NikoSpace.s2,
                  children: [
                    NikoPrimaryButton(
                      label: _running ? strings.whyRunning : strings.whyStart,
                      onPressed: _running ? null : _start,
                    ),
                    if (_reportText.isNotEmpty) ...[
                      NikoTonalButton(label: strings.whyCopyReport, onPressed: () => unawaited(_copyReport(strings))),
                      NikoTonalButton(label: strings.whySaveReport, onPressed: () => unawaited(_saveReport(strings))),
                    ],
                  ],
                ),
                if (_notice.isNotEmpty) ...[
                  const SizedBox(height: NikoSpace.s4),
                  NikoBanner(icon: NikoIcons.copy, title: _notice),
                ],
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: NikoSpace.s4),
                  NikoBanner(icon: NikoIcons.alert, title: strings.errorTitle, text: _error, danger: true),
                ],
                if (findings != null) ...[
                  if (working.isNotEmpty && failing.isNotEmpty) ...[
                    const SizedBox(height: NikoSpace.s5),
                    Builder(builder: (context) {
                      final sorted = [...working]..sort((a, b) => a.firstByteMs.compareTo(b.firstByteMs));
                      final best = sorted.first;
                      final broken = failing.first;
                      return NikoBanner(
                        icon: NikoIcons.rotateCw,
                        title: strings.whyRecommendTitle,
                        text: '${broken.name} (${strings.whyCause(broken.cause)}) · ${best.name} (${best.firstByteMs} ms)',
                        action: widget.onSwitchToName != null ? strings.whyRecommendSwitch(best.name) : null,
                        onAction: widget.onSwitchToName != null ? () => widget.onSwitchToName!(best.name) : null,
                      );
                    }),
                  ],
                  if (findings.notes.isNotEmpty) ...[
                    const SizedBox(height: NikoSpace.s6),
                    NikoSection(
                      overline: strings.whyNotes,
                      rows: [
                        for (final n in findings.notes)
                          NikoInfoRow(
                            title: strings.whyNoteText(n.note, n.number, n.detail),
                            value: n.note,
                          ),
                      ],
                    ),
                  ],
                  if (working.isNotEmpty) ...[
                    const SizedBox(height: NikoSpace.s6),
                    NikoSection(
                      overline: '${strings.whyWorking} (${working.length})',
                      rows: [
                        for (final p in working)
                          NikoInfoRow(
                            title: p.relay.isNotEmpty ? '${p.name} · ${p.relay}' : p.name,
                            value: p.kbps > 0
                                ? '${p.firstByteMs} ms · ${(p.kbps / 1000).toStringAsFixed(1)} Mbps'
                                : '${p.firstByteMs} ms',
                          ),
                      ],
                    ),
                  ],
                  if (failing.isNotEmpty) ...[
                    const SizedBox(height: NikoSpace.s6),
                    NikoSection(
                      overline: '${strings.whyFailing} (${failing.length})',
                      rows: [
                        for (final p in failing)
                          NikoInfoRow(
                            title: p.relay.isNotEmpty ? '${p.name} · ${p.relay}' : p.name,
                            value: strings.whyCause(p.cause),
                          ),
                      ],
                    ),
                  ],
                ],
                if (_events.isNotEmpty) ...[
                  const SizedBox(height: NikoSpace.s6),
                  Text(strings.whySteps.toUpperCase(), style: NikoType.label.style(colors.ink2)),
                  const SizedBox(height: NikoSpace.s2),
                  Container(
                    padding: const EdgeInsets.all(NikoSpace.s4),
                    decoration: BoxDecoration(
                      color: colors.surface1,
                      borderRadius: BorderRadius.circular(NikoRadius.md),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final ev in _events)
                          Padding(
                            padding: const EdgeInsets.only(bottom: NikoSpace.s1),
                            child: Text(
                              '${ev.step}: ${ev.line}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: NikoType.code.style(colors.ink2),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
