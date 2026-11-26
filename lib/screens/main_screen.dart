import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';

import '../daemon/daemon.dart';
import '../l10n/strings.dart';
import '../platform/service_install.dart';
import '../platform/user_store_migration.dart';
import '../state/connection_controller.dart';
import '../theme/niko_theme.dart';
import '../ui/banner.dart';
import '../ui/connect_button.dart';
import '../ui/controls.dart';
import '../ui/format.dart';
import '../ui/icons.dart';
import '../ui/list.dart';
import '../ui/status_block.dart';
import 'nodes_screen.dart' show nodeUsage, nodeUpdates;

/// The main screen in the view Простой (B · Simple on the canvas), as far as stage 2b goes: the connect button, the
/// status with the time and the rates, the reason of a failure. Without a config of the window's the button connects
/// the daemon's selected profile (NikoService.Connect) in the mode chosen under the status (D-NAV-02). The node and the
/// other tiles come with NikoService (stage 3); what stands in their place is the development group, marked as such.
/// The header is the shell's.
class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.controller,
    this.daemonAddress = '',
    this.configName = '',
    this.now = DateTime.now,
    this.mode,
    this.onMode,
    this.node,
    this.serviceInstall,
    this.userMigration,
  });

  final ConnectionController controller;

  /// Windows/Linux release service installer controller when running without an installed service link.
  final ServiceController? serviceInstall;

  /// One-time migration controller from unprivileged user-mode store to system service store.
  final UserStoreMigrationController? userMigration;

  /// The raycontrol node of the selected profile, for its term, traffic and last update (D-MAIN-13); null for none.
  final NodeRow? node;

  /// The mode the button connects the selected profile in (D-NAV-02): the settings'; null where the button starts a
  /// config of the window's, or the settings are not read yet, and nothing is chosen here.
  final ConnectMode? mode;
  final ValueChanged<ConnectMode>? onMode;

  /// For the development group: where the daemon was asked for, and the config's file.
  final String daemonAddress;
  final String configName;

  /// The clock the time in the status is counted by (a test's own).
  final DateTime Function() now;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.serviceInstall?.addListener(_changed);
    widget.userMigration?.addListener(_changed);
    _syncClock();
  }

  @override
  void didUpdateWidget(MainScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    if (oldWidget.serviceInstall != widget.serviceInstall) {
      oldWidget.serviceInstall?.removeListener(_changed);
      widget.serviceInstall?.addListener(_changed);
    }
    if (oldWidget.userMigration != widget.userMigration) {
      oldWidget.userMigration?.removeListener(_changed);
      widget.userMigration?.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.serviceInstall?.removeListener(_changed);
    widget.userMigration?.removeListener(_changed);
    _clock?.cancel();
    super.dispose();
  }

  void _changed() {
    _syncClock();
    setState(() {});
  }

  // the time in the status ticks by itself while connected, and nothing ticks otherwise
  void _syncClock() {
    final ticking = widget.controller.startedAt != null;
    if (ticking && _clock == null) {
      _clock = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    } else if (!ticking && _clock != null) {
      _clock!.cancel();
      _clock = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = NikoStrings.of(Localizations.localeOf(context));
    final state = widget.controller;
    final phase = state.service.phase;
    final ready = state.link == LinkPhase.ready;

    // a press that the daemon has not answered yet already shows where it leads
    final starting = phase == ServicePhase.starting || (state.busy && phase != ServicePhase.started);
    final failed = ready && !state.busy && (phase == ServicePhase.fatal || state.actionError.isNotEmpty);
    final ConnectLook look;
    final String label, status;
    final StatusTone tone;
    if (ready && phase == ServicePhase.stopping) {
      (look, label, status, tone) = (ConnectLook.connecting, strings.disconnect, strings.statusStopping, StatusTone.quiet);
    } else if (ready && phase == ServicePhase.started) {
      (look, label, status, tone) = (ConnectLook.on, strings.disconnect, strings.statusOn, StatusTone.on);
    } else if (ready && starting) {
      (look, label, status, tone) = (ConnectLook.connecting, strings.disconnect, strings.statusConnecting, StatusTone.quiet);
    } else if (failed) {
      (look, label, status, tone) = (ConnectLook.error, strings.retry, strings.statusError, StatusTone.error);
    } else {
      (look, label, status, tone) = (ConnectLook.off, strings.connect, strings.statusOff, StatusTone.quiet);
    }

    final traffic = state.traffic;
    final startedAt = state.startedAt;
    final detail = phase == ServicePhase.started && ready
        ? [
            if (startedAt != null) formatElapsed(widget.now().difference(startedAt)),
            if (traffic != null) '↓ ${formatRate(traffic.down)}',
            if (traffic != null) '↑ ${formatRate(traffic.up)}',
          ].join(' · ')
        : '';

    final error = phase == ServicePhase.fatal && state.service.error.isNotEmpty ? state.service.error : state.actionError;
    final canPress = ready && !state.busy && phase != ServicePhase.stopping && (state.canStart || phase == ServicePhase.started);
    final mode = widget.mode;

    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(NikoSpace.s8, NikoSpace.s8, NikoSpace.s8, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // D-MAIN-04
                Center(
                  child: ConnectButton(
                    look: look,
                    label: label,
                    onPressed: canPress ? () => state.toggle(mode: mode) : null,
                  ),
                ),
                const SizedBox(height: NikoSpace.s4),
                // D-MAIN-02, D-MAIN-06
                StatusBlock(label: status, detail: detail, tone: tone),
                // D-NAV-02: the mode, chosen here as in the settings; a running core is started again in it
                if (state.connectsProfile && mode != null) ...[
                  const SizedBox(height: NikoSpace.s6),
                  Center(
                    child: NikoSegmented<ConnectMode>(
                      label: strings.setMode,
                      choices: [(ConnectMode.proxy, strings.setModeProxy), (ConnectMode.vpn, strings.setModeVpn)],
                      value: mode,
                      onChanged: ready && !state.busy ? (m) => widget.onMode?.call(m) : (_) {},
                    ),
                  ),
                ],
                // D-MAIN-13: the node of the selected profile, its term and traffic, when it was updated
                if (widget.node case final node? when ready) ...[
                  const SizedBox(height: NikoSpace.s6),
                  NikoSection(
                    overline: strings.mainNode,
                    rows: [
                      NikoInfoRow(
                        title: node.name,
                        value: [nodeUsage(node, strings), nodeUpdates(node, strings)].where((p) => p.isNotEmpty).join(' · '),
                      ),
                    ],
                  ),
                ],
                // D-MAIN-16
                if (failed && error.isNotEmpty) ...[
                  const SizedBox(height: NikoSpace.s6),
                  NikoBanner(icon: NikoIcons.alert, title: strings.errorTitle, text: error, danger: true),
                ],
                if (state.isUserMode) ...[
                  const SizedBox(height: NikoSpace.s6),
                  ..._buildUserModeBanner(strings, vpnRequested: mode == ConnectMode.vpn || error.contains('SERVICE_REQUIRED')),
                ],
                if (ready && state.privileged && widget.userMigration != null) ...[
                  ..._buildMigrationBanner(strings, widget.userMigration!),
                ],
                if (state.link == LinkPhase.none) ...[
                  const SizedBox(height: NikoSpace.s6),
                  ..._buildNoServiceBanner(strings),
                ],
                if (state.link == LinkPhase.lost) ...[
                  const SizedBox(height: NikoSpace.s6),
                  NikoBanner(
                    icon: NikoIcons.alert,
                    title: strings.serviceSilentTitle,
                    text: state.linkError,
                    danger: true,
                  ),
                ],
                if (ready && !state.canStart) ...[
                  const SizedBox(height: NikoSpace.s6),
                  if (widget.daemonAddress.isNotEmpty)
                    NikoBanner(icon: NikoIcons.alert, title: strings.noConfigTitle, text: '--config <file.json>')
                  else
                    NikoBanner(
                      icon: NikoIcons.alert,
                      title: strings.oldServiceTitle,
                      text: strings.oldServiceText(ConnectionController.connectApi, state.nikoApi),
                    ),
                ],
                if (widget.daemonAddress.isNotEmpty) ...[
                  const SizedBox(height: NikoSpace.s8),
                  NikoSection(
                    overline: strings.development,
                    rows: [
                      NikoInfoRow(
                        title: strings.service,
                        value: [widget.daemonAddress, if (state.daemonVersion.isNotEmpty) state.daemonVersion]
                            .join(' · '),
                      ),
                      if (widget.configName.isNotEmpty)
                        NikoInfoRow(title: strings.config, value: widget.configName),
                      if (traffic != null)
                        NikoInfoRow(
                          title: strings.session,
                          value: '↓ ${formatBytes(traffic.downTotal)} · ↑ ${formatBytes(traffic.upTotal)}',
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
  }

  List<Widget> _buildUserModeBanner(NikoStrings strings, {required bool vpnRequested}) {
    final installer = widget.serviceInstall;
    final outcomeText = installer == null ? '' : _installOutcomeMessage(installer, strings);
    final isDanger = vpnRequested ||
        (installer != null &&
            installer.lastOutcome != null &&
            installer.lastOutcome != InstallOutcome.ok &&
            installer.lastOutcome != InstallOutcome.cancelled);
    final title = vpnRequested ? strings.vpnNeedsServiceTitle : strings.userModeTitle;
    final body = outcomeText.isNotEmpty
        ? outcomeText
        : (vpnRequested ? strings.vpnNeedsServiceText : strings.userModeText);
    final widgets = <Widget>[
      NikoBanner(
        icon: NikoIcons.alert,
        title: title,
        text: body,
        danger: isDanger,
        action: installer == null
            ? null
            : (installer.installing ? strings.installingService : strings.installService),
        onAction: installer == null || installer.installing
            ? null
            : () => unawaited(installer.installService()),
      ),
    ];
    if (installer != null &&
        installer.lastOutcome == InstallOutcome.polkitUnavailable &&
        installer.manualCommand.isNotEmpty) {
      widgets.addAll([
        const SizedBox(height: NikoSpace.s3),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: NikoTonalButton(
            label: strings.copyCommand,
            onPressed: () => unawaited(Clipboard.setData(ClipboardData(text: installer.manualCommand))),
          ),
        ),
      ]);
    }
    return widgets;
  }

  List<Widget> _buildMigrationBanner(NikoStrings strings, UserStoreMigrationController migration) {
    if (migration.imported case final res? when !res.isEmpty) {
      return [
        const SizedBox(height: NikoSpace.s6),
        NikoBanner(
          icon: NikoIcons.alert,
          title: strings.migrationDone(res.profiles, res.rules, res.nodes),
        ),
      ];
    }
    if (!migration.visible) return const [];
    final text = migration.error.isNotEmpty ? migration.error : strings.migrationText;
    return [
      const SizedBox(height: NikoSpace.s6),
      NikoBanner(
        icon: NikoIcons.alert,
        title: strings.migrationTitle,
        text: text,
        danger: migration.error.isNotEmpty,
        action: migration.migrating ? strings.migrationBusy : strings.migrationAction,
        onAction: migration.migrating ? null : () => unawaited(migration.migrateNow()),
      ),
      if (!migration.migrating) ...[
        const SizedBox(height: NikoSpace.s3),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: NikoTonalButton(
            label: strings.migrationDismiss,
            onPressed: migration.dismiss,
          ),
        ),
      ],
    ];
  }

  List<Widget> _buildNoServiceBanner(NikoStrings strings) {
    final installer = widget.serviceInstall;
    if (installer == null) {
      return [NikoBanner(icon: NikoIcons.alert, title: strings.noServiceTitle)];
    }
    final outcomeText = _installOutcomeMessage(installer, strings);
    final isDanger = installer.lastOutcome != null &&
        installer.lastOutcome != InstallOutcome.ok &&
        installer.lastOutcome != InstallOutcome.cancelled;
    if (installer.mode == InstallMode.portableServiceReady) {
      return [
        NikoBanner(
          icon: NikoIcons.alert,
          title: strings.portableInstalledTitle,
          text: outcomeText.isNotEmpty ? outcomeText : strings.portableInstalledText,
          danger: isDanger,
          action: installer.installing ? strings.installingService : strings.openInstalled,
          onAction: installer.installing ? null : () => unawaited(installer.openInstalled()),
        ),
        const SizedBox(height: NikoSpace.s3),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: NikoTonalButton(
            label: installer.installing ? strings.installingService : strings.updateService,
            onPressed: installer.installing ? null : () => unawaited(installer.installService()),
          ),
        ),
      ];
    }
    final defaultInstallText =
        installer.manualCommand.isNotEmpty ? strings.noServiceInstallLinuxText : strings.noServiceInstallText;
    final widgets = <Widget>[
      NikoBanner(
        icon: NikoIcons.alert,
        title: strings.noServiceTitle,
        text: outcomeText.isNotEmpty ? outcomeText : defaultInstallText,
        danger: isDanger,
        action: installer.installing ? strings.installingService : strings.installService,
        onAction: installer.installing ? null : () => unawaited(installer.installService()),
      ),
    ];
    if (installer.lastOutcome == InstallOutcome.polkitUnavailable && installer.manualCommand.isNotEmpty) {
      widgets.addAll([
        const SizedBox(height: NikoSpace.s3),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: NikoTonalButton(
            label: strings.copyCommand,
            onPressed: () => unawaited(Clipboard.setData(ClipboardData(text: installer.manualCommand))),
          ),
        ),
      ]);
    }
    return widgets;
  }

  String _installOutcomeMessage(ServiceController installer, NikoStrings strings) {
    final outcome = installer.lastOutcome;
    if (outcome == null || outcome == InstallOutcome.ok) return '';
    return switch (outcome) {
      InstallOutcome.ok => '',
      InstallOutcome.cancelled => strings.installCancelled,
      InstallOutcome.polkitUnavailable => installer.manualCommand.isNotEmpty
          ? '${strings.installPolkitUnavailable}\n${installer.manualCommand}'
          : strings.installPolkitUnavailable,
      InstallOutcome.notElevated => strings.installNotElevated,
      InstallOutcome.invalidLayout => strings.installInvalidLayout,
      InstallOutcome.signatureFailed => strings.installSignatureFailed,
      InstallOutcome.manifestFailed => strings.installManifestFailed,
      InstallOutcome.targetBusy => strings.installTargetBusy,
      InstallOutcome.invalidSource => strings.installInvalidSource,
      InstallOutcome.installedButLaunchFailed =>
        installer.lastError.isNotEmpty ? '${strings.installLaunchFailed}: ${installer.lastError}' : strings.installLaunchFailed,
      InstallOutcome.failed =>
        installer.lastError.isNotEmpty ? '${strings.installFailed}: ${installer.lastError}' : strings.installFailed,
    };
  }
}
