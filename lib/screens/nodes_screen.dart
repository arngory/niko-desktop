import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../daemon/daemon.dart';
import '../l10n/strings.dart';
import '../state/profiles_feed.dart';
import '../theme/niko_theme.dart';
import '../ui/banner.dart';
import '../ui/controls.dart';
import '../ui/dialog.dart';
import '../ui/fields.dart';
import '../ui/format.dart';
import '../ui/header.dart';
import '../ui/icons.dart';
import '../ui/list.dart';
import '../ui/pressable.dart';
import 'profile_editor.dart';

/// Узлы (B-Profiles, D-MAIN-07, D-GROUP-01, D-SUB-01..08, D-PROFILE-01..05, D-MAIN-08/12):
/// groups beside profiles, custom group management, subscription settings/update-all/copy/delete,
/// raycontrol node cards, per-profile latency testing, and manual profile creation/editing.
class NodesScreen extends StatefulWidget {
  const NodesScreen({super.key, required this.feed, required this.linked, required this.onAdd});

  final ProfilesFeed feed;

  /// The window talks to the daemon: without it the store cannot be read.
  final bool linked;
  final VoidCallback onAdd;

  @override
  State<NodesScreen> createState() => _NodesScreenState();
}

class _NodesScreenState extends State<NodesScreen> {
  // Dialogs & inline overlays
  GroupRow? _editingGroup; // id 0 = new basic group; >0 = rename basic group or edit subscription settings
  bool _confirmDeleteGroup = false;
  // Manual profile editor state
  bool _editingProfile = false;
  int _editProfileId = 0;
  String _editProfileType = 'socks';
  String _editProfileJson = '';

  Future<void> _openProfileEditor({ProfileRow? existing}) async {
    if (existing == null) {
      setState(() {
        _editingProfile = true;
        _editProfileId = 0;
        _editProfileType = 'socks';
        _editProfileJson = '';
      });
      return;
    }
    final saved = await widget.feed.loadProfile(existing.id);
    if (!mounted || saved == null) return;
    setState(() {
      _editingProfile = true;
      _editProfileId = saved.row.id;
      _editProfileType = saved.row.type;
      _editProfileJson = saved.beanJson;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final strings = NikoStrings.of(Localizations.localeOf(context));
    final feed = widget.feed;
    final linked = widget.linked;
    final group = feed.groups.where((g) => g.id == feed.groupId).firstOrNull;
    final hasSubscriptions = feed.groups.any((g) => g.subscription);
    final canAddManual = group != null && !group.subscription && group.nodeId.isEmpty;

    if (_editingProfile) {
      return ProfileEditor(
        key: ValueKey('profile-edit-$_editProfileId'),
        strings: strings,
        profileId: _editProfileId,
        groupId: feed.importGroup,
        initialType: _editProfileType,
        initialBeanJson: _editProfileJson,
        onSave: ({required int id, required int groupId, required String type, required String beanJson}) async {
          final err = await feed.saveProfile(id: id, groupId: groupId, type: type, beanJson: beanJson);
          if (err == null && mounted) {
            setState(() => _editingProfile = false);
          }
          return err;
        },
        onCancel: () => setState(() => _editingProfile = false),
      );
    }

    Widget buildProfiles({required bool scrollable}) {
      if (!linked) {
        return NikoBanner(icon: NikoIcons.alert, title: strings.storeNoLink);
      } else if (!feed.loaded) {
        return const SizedBox.shrink();
      } else if (feed.profiles.isEmpty) {
        return Text(strings.groupEmpty, style: NikoType.body.style(colors.ink2));
      }
      final share = !feed.shownIsNode;
      Widget row(int i) {
        final p = feed.profiles[i];
        return _ProfileRow(
          key: ValueKey(p.id),
          profile: p,
          selected: p.id == feed.selected,
          divider: i > 0,
          latency: feed.latencies[p.id],
          onPressed: () => feed.select(p.id),
          onEdit: canAddManual ? () => unawaited(_openProfileEditor(existing: p)) : null,
          onDelete: () => feed.delete(p),
          onShare: share ? () => feed.share(p, copyText) : null,
        );
      }

      final card = Semantics(
        container: true,
        explicitChildNodes: true,
        label: strings.profilesList,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(NikoRadius.md),
          child: ColoredBox(
            color: colors.surface1,
            child: scrollable
                ? ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: feed.profiles.length,
                    itemBuilder: (context, i) => row(i),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (var i = 0; i < feed.profiles.length; i++) row(i)],
                  ),
          ),
        ),
      );
      return scrollable ? Flexible(child: card) : card;
    }

    List<Widget> detailChildren({required bool scrollable}) => [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    group == null ? strings.sectionNodes : groupName(group, strings),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NikoType.title.style(colors.ink),
                  ),
                ),
              ),
              if (linked && feed.profiles.isNotEmpty) ...[
                const SizedBox(width: NikoSpace.s2),
                NikoTonalButton(
                  label: feed.testing ? strings.profileTesting : strings.profileTestAll,
                  onPressed: feed.testing ? null : () => unawaited(feed.testGroupProfiles(feed.groupId)),
                ),
              ],
              if (linked && canAddManual) ...[
                const SizedBox(width: NikoSpace.s2),
                NikoTonalButton(
                  label: strings.profileNew,
                  onPressed: () => unawaited(_openProfileEditor()),
                ),
              ],
            ],
          ),
          if (group != null && linked && !group.ungrouped && !group.subscription && group.nodeId.isEmpty) ...[
            const SizedBox(height: NikoSpace.s2),
            Wrap(
              spacing: NikoSpace.s2,
              runSpacing: NikoSpace.s2,
              children: [
                NikoGhostButton(
                  label: strings.groupRename,
                  onPressed: () => setState(() {
                    _confirmDeleteGroup = false;
                    _editingGroup = group;
                  }),
                ),
                NikoGhostButton(
                  label: strings.groupDelete,
                  onPressed: () => setState(() => _confirmDeleteGroup = true),
                ),
              ],
            ),
          ],
          if (group != null && linked && feed.nodeOfGroup(group.id) != null) ...[
            const SizedBox(height: NikoSpace.s2),
            NodeCard(
              key: ValueKey('node-${group.nodeId}'),
              node: feed.nodeOfGroup(group.id)!,
              strings: strings,
              onUpdate: () => feed.refreshNode(group.nodeId),
              onDelete: () => feed.deleteNode(group.nodeId),
            ),
          ] else if (group?.info case final info? when linked) ...[
            const SizedBox(height: NikoSpace.s2),
            _SubscriptionLine(
              info: info,
              strings: strings,
              onUpdate: info.updating ? null : () => feed.refresh(group!.id),
              onSettings: () => setState(() {
                _confirmDeleteGroup = false;
                _editingGroup = group;
              }),
              onCopyLink: info.link.isEmpty
                  ? null
                  : () => unawaited(feed.copyNotice(info.link, strings.subscriptionLinkCopied, copyText)),
              onDelete: () => setState(() => _confirmDeleteGroup = true),
            ),
          ],
          if (_confirmDeleteGroup && group != null && !group.ungrouped && group.nodeId.isEmpty) ...[
            const SizedBox(height: NikoSpace.s3),
            NikoBanner(
              icon: NikoIcons.trash,
              title: strings.groupDeleteConfirm(groupName(group, strings)),
              danger: true,
            ),
            const SizedBox(height: NikoSpace.s2),
            Row(
              children: [
                NikoPrimaryButton(
                  label: group.subscription ? strings.subscriptionDelete : strings.groupDelete,
                  onPressed: () {
                    final id = group.id;
                    setState(() => _confirmDeleteGroup = false);
                    unawaited(feed.deleteGroup(id));
                  },
                ),
                const SizedBox(width: NikoSpace.s3),
                NikoGhostButton(
                  label: strings.cancel,
                  onPressed: () => setState(() => _confirmDeleteGroup = false),
                ),
              ],
            ),
          ],
          const SizedBox(height: NikoSpace.s4),
          if (feed.error.isNotEmpty) ...[
            NikoBanner(icon: NikoIcons.alert, title: strings.storeUnreachable, text: feed.error, danger: true),
            const SizedBox(height: NikoSpace.s4),
          ],
          buildProfiles(scrollable: scrollable),
          if (feed.deleted case final gone?) ...[
            const SizedBox(height: NikoSpace.s4),
            _Snackbar(text: strings.profileDeleted(gone.saved.row.name), action: strings.undo, onAction: feed.undo),
          ] else if (feed.copied case final name?) ...[
            const SizedBox(height: NikoSpace.s4),
            _Snackbar(text: name == strings.subscriptionLinkCopied ? name : strings.linkCopied(name)),
          ] else if (feed.updated case final line?) ...[
            const SizedBox(height: NikoSpace.s4),
            _Snackbar(
              text: !feed.updateFailed
                  ? line
                  : group?.nodeId.isNotEmpty == true
                      ? '${strings.nodeUpdateFailed}: $line'
                      : '${strings.subscriptionUpdateFailed}: $line',
            ),
          ],
        ];

    final mainLayout = LayoutBuilder(
      builder: (context, constraints) {
        final pad = constraints.maxWidth < NikoHeader.narrow ? NikoSpace.s4 : NikoSpace.s8;
        final available = constraints.maxWidth - 2 * pad;
        final groupsWidget = _Groups(
          feed: feed,
          strings: strings,
          onAdd: linked ? widget.onAdd : null,
          onNewGroup: linked ? () => setState(() => _editingGroup = const GroupRow(id: 0, name: '')) : null,
          onUpdateAll: linked && hasSubscriptions ? () => unawaited(feed.refreshAllSubscriptions()) : null,
          onChoose: (id) {
            setState(() => _confirmDeleteGroup = false);
            unawaited(feed.choose(id));
          },
          scrollable: constraints.maxWidth >= 840,
        );
        if (constraints.maxWidth >= 840) {
          return Padding(
            padding: EdgeInsets.fromLTRB(pad, NikoSpace.s4, pad, NikoSpace.s8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 260, child: groupsWidget),
                const SizedBox(width: NikoSpace.s6),
                Expanded(
                  child: CustomScrollView(
                    slivers: [SliverList.list(children: detailChildren(scrollable: false))],
                  ),
                ),
              ],
            ),
          );
        }
        final groupWidth = available > 0 ? math.min(available, 320.0) : 320.0;
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad, NikoSpace.s4, pad, NikoSpace.s8),
              sliver: SliverList.list(
                children: [
                  Align(
                    alignment: AlignmentDirectional.topStart,
                    child: SizedBox(width: groupWidth, child: groupsWidget),
                  ),
                  const SizedBox(height: NikoSpace.s6),
                  ...detailChildren(scrollable: false),
                ],
              ),
            ),
          ],
        );
      },
    );

    if (_editingGroup == null) return mainLayout;

    final edit = _editingGroup!;
    return Stack(
      children: [
        mainLayout,
        if (edit.subscription)
          _SubscriptionDialog(
            group: edit,
            strings: strings,
            onSave: (updated) async {
              final err = await feed.saveGroup(updated);
              if (err == null && mounted) setState(() => _editingGroup = null);
              return err;
            },
            onClose: () => setState(() => _editingGroup = null),
          )
        else
          _BasicGroupDialog(
            group: edit,
            strings: strings,
            onSave: (updated) async {
              final err = await feed.saveGroup(updated);
              if (err == null && mounted) setState(() => _editingGroup = null);
              return err;
            },
            onClose: () => setState(() => _editingGroup = null),
          ),
      ],
    );
  }
}

/// Dialog for creating or renaming a basic group (D-GROUP-01).
class _BasicGroupDialog extends StatefulWidget {
  const _BasicGroupDialog({
    required this.group,
    required this.strings,
    required this.onSave,
    required this.onClose,
  });

  final GroupRow group;
  final NikoStrings strings;
  final Future<String?> Function(GroupRow) onSave;
  final VoidCallback onClose;

  @override
  State<_BasicGroupDialog> createState() => _BasicGroupDialogState();
}

class _BasicGroupDialogState extends State<_BasicGroupDialog> {
  late String _name = widget.group.name;
  String _error = '';
  bool _saving = false;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = '';
    });
    final err = await widget.onSave(GroupRow(id: widget.group.id, name: _name.trim()));
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _saving = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    return NikoDialog(
      title: widget.group.id == 0 ? s.groupNew : s.groupRename,
      cancelLabel: s.cancel,
      saveLabel: s.save,
      errorTitle: s.saveFailed,
      error: _error,
      onClose: widget.onClose,
      onSave: _saving ? null : _save,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NikoField(label: s.groupNameField, value: _name, onChanged: (v) => _name = v),
          const SizedBox(height: NikoSpace.s4),
        ],
      ),
    );
  }
}

/// Dialog for editing a subscription group's settings (D-SUB-08).
class _SubscriptionDialog extends StatefulWidget {
  const _SubscriptionDialog({
    required this.group,
    required this.strings,
    required this.onSave,
    required this.onClose,
  });

  final GroupRow group;
  final NikoStrings strings;
  final Future<String?> Function(GroupRow) onSave;
  final VoidCallback onClose;

  @override
  State<_SubscriptionDialog> createState() => _SubscriptionDialogState();
}

class _SubscriptionDialogState extends State<_SubscriptionDialog> {
  late String _name = widget.group.name;
  late String _link = widget.group.info?.link ?? '';
  late bool _autoUpdate = widget.group.info?.autoUpdate ?? false;
  late String _delay = '${widget.group.info?.autoUpdateDelay ?? 1440}';
  late bool _dedup = widget.group.info?.deduplication ?? false;
  late bool _forceResolve = widget.group.info?.forceResolve ?? false;
  late bool _whenConnected = widget.group.info?.updateWhenConnectedOnly ?? false;
  late String _ua = widget.group.info?.customUserAgent ?? '';
  String _error = '';
  bool _saving = false;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = '';
    });
    final delay = int.tryParse(_delay.trim()) ?? 1440;
    final info = (widget.group.info ?? const SubscriptionInfo()).copyWith(
      link: _link.trim(),
      autoUpdate: _autoUpdate,
      autoUpdateDelay: delay,
      deduplication: _dedup,
      forceResolve: _forceResolve,
      updateWhenConnectedOnly: _whenConnected,
      customUserAgent: _ua.trim(),
    );
    final err = await widget.onSave(
      GroupRow(id: widget.group.id, name: _name.trim(), subscription: true, info: info),
    );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _saving = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    return NikoDialog(
      title: s.subscriptionSettings,
      maxWidth: 520,
      cancelLabel: s.cancel,
      saveLabel: s.save,
      errorTitle: s.saveFailed,
      error: _error,
      onClose: widget.onClose,
      onSave: _saving ? null : _save,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NikoField(label: s.groupNameField, value: _name, onChanged: (v) => _name = v),
          const SizedBox(height: NikoSpace.s3),
          NikoField(label: s.subscriptionLink, value: _link, mono: true, onChanged: (v) => _link = v),
          const SizedBox(height: NikoSpace.s3),
          NikoField(label: s.subscriptionDelay, value: _delay, input: FieldInput.port, mono: true, onChanged: (v) => _delay = v),
          const SizedBox(height: NikoSpace.s3),
          NikoField(label: s.subscriptionUserAgent, value: _ua, mono: true, onChanged: (v) => _ua = v),
          const SizedBox(height: NikoSpace.s3),
          NikoGroup(
            rows: [
              NikoSwitchRow(
                title: s.subscriptionAutoUpdate,
                on: _autoUpdate,
                divider: false,
                onChanged: (v) => setState(() => _autoUpdate = v),
              ),
              NikoSwitchRow(
                title: s.subscriptionDedup,
                on: _dedup,
                divider: true,
                onChanged: (v) => setState(() => _dedup = v),
              ),
              NikoSwitchRow(
                title: s.subscriptionForceResolve,
                on: _forceResolve,
                divider: true,
                onChanged: (v) => setState(() => _forceResolve = v),
              ),
              NikoSwitchRow(
                title: s.subscriptionWhenConnected,
                on: _whenConnected,
                divider: true,
                onChanged: (v) => setState(() => _whenConnected = v),
              ),
            ],
          ),
          const SizedBox(height: NikoSpace.s4),
        ],
      ),
    );
  }
}

/// A group's name: the ungrouped one is the window's to name.
String groupName(GroupRow group, NikoStrings strings) =>
    group.ungrouped || group.name.isEmpty ? strings.groupOwn : group.name;

/// What a subscription's provider said of it: the traffic used of the allowed (or used alone), the expiry; empty
/// where it said nothing.
String subscriptionUsage(SubscriptionInfo info, NikoStrings strings) => [
      if (info.total > 0)
        strings.subscriptionTraffic(formatBytes(info.used), formatBytes(info.total))
      else if (info.used > 0)
        strings.subscriptionUsed(formatBytes(info.used)),
      if (info.expire > 0) strings.subscriptionExpires(formatDate(DateTime.fromMillisecondsSinceEpoch(info.expire * 1000))),
    ].join(' · ');

/// What a node's last subscription said of the user (D-NODE-04, D-MAIN-13): the traffic used of the limit, used up,
/// the term; empty where it said nothing.
String nodeUsage(NodeRow node, NikoStrings strings) {
  String at(int seconds) => formatDate(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
  final traffic = node.traffic;
  return [
    if (traffic != null && traffic.exhausted)
      traffic.reset > 0 ? strings.nodeTrafficExhausted(at(traffic.reset)) : strings.nodeTrafficExhaustedAdmin
    else if (traffic != null && traffic.limit > 0)
      [
        strings.nodeTraffic(formatBytes(traffic.used), formatBytes(traffic.limit)),
        if (traffic.reset > 0) strings.nodeTrafficReset(at(traffic.reset)),
      ].join(', '),
    if (node.expires > 0) strings.subscriptionExpires(at(node.expires)),
  ].join(' · ');
}

/// When a node's subscription came, and when the next comes (D-NODE-05).
String nodeUpdates(NodeRow node, NikoStrings strings) {
  String at(int seconds) => formatMoment(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
  return [
    node.updated > 0 ? strings.nodeUpdated(at(node.updated)) : strings.nodeNever,
    if (node.nextUpdate > 0 && !node.refused) strings.nodeNext(at(node.nextUpdate)),
  ].join(' · ');
}

/// A node's card under its group's title (D-NODE-01…07).
class NodeCard extends StatefulWidget {
  const NodeCard({super.key, required this.node, required this.strings, required this.onUpdate, required this.onDelete});

  final NodeRow node;
  final NikoStrings strings;
  final VoidCallback onUpdate;
  final VoidCallback onDelete;

  @override
  State<NodeCard> createState() => _NodeCardState();
}

class _NodeCardState extends State<NodeCard> {
  bool _confirming = false;

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final strings = widget.strings;
    final node = widget.node;
    final usage = nodeUsage(node, strings);
    final problems = [
      if (node.failed > 0 && !node.refused)
        [strings.nodeFailing(node.failed), if (node.error.isNotEmpty) node.error].join(': '),
      if (node.clockSkew.abs() > 30) strings.nodeClock(node.clockSkew),
      if (node.minVersion.isNotEmpty && node.refusedVersion) strings.nodeMinVersion(node.minVersion),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (node.note.isNotEmpty)
          Text('\u2068${node.note}\u2069', maxLines: 3, overflow: TextOverflow.ellipsis, style: NikoType.body.style(colors.ink)),
        if (usage.isNotEmpty)
          Text(
            usage,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: NikoType.bodySm.style(node.traffic?.exhausted == true ? colors.danger : colors.ink2),
          ),
        Text(nodeUpdates(node, strings), maxLines: 2, overflow: TextOverflow.ellipsis, style: NikoType.bodySm.style(colors.ink2)),
        if (node.subscription && node.updated > 0)
          Text(strings.nodeSigned, maxLines: 2, style: NikoType.bodySm.style(colors.ink2)),
        const SizedBox(height: NikoSpace.s3),
        Wrap(
          spacing: NikoSpace.s2,
          runSpacing: NikoSpace.s2,
          children: [
            NikoTonalButton(
              label: node.updating ? strings.subscriptionUpdating : strings.subscriptionUpdate,
              onPressed: node.updating || node.refused || node.unreadable || !node.subscription ? null : widget.onUpdate,
            ),
            NikoGhostButton(label: strings.nodeDelete, onPressed: () => setState(() => _confirming = true)),
          ],
        ),
        if (node.refused || node.unreadable) ...[
          const SizedBox(height: NikoSpace.s3),
          NikoBanner(icon: NikoIcons.alert, title: node.unreadable ? strings.nodeUnreadable : strings.nodeRefused, danger: true),
        ],
        for (final problem in problems) ...[
          const SizedBox(height: NikoSpace.s2),
          NikoBanner(icon: NikoIcons.alert, title: problem),
        ],
        if (_confirming) ...[
          const SizedBox(height: NikoSpace.s3),
          NikoBanner(icon: NikoIcons.trash, title: strings.nodeDeleteConfirm(node.name), danger: true),
          const SizedBox(height: NikoSpace.s2),
          Row(
            children: [
              NikoPrimaryButton(
                label: strings.nodeDelete,
                onPressed: () {
                  setState(() => _confirming = false);
                  widget.onDelete();
                },
              ),
              const SizedBox(width: NikoSpace.s3),
              NikoGhostButton(label: strings.cancel, onPressed: () => setState(() => _confirming = false)),
            ],
          ),
        ],
      ],
    );
  }
}

/// A subscription's group under its title: usage, announcement, update, settings (D-SUB-08), copy link (D-SUB-06), delete (D-SUB-04).
class _SubscriptionLine extends StatelessWidget {
  const _SubscriptionLine({
    required this.info,
    required this.strings,
    required this.onUpdate,
    required this.onSettings,
    required this.onCopyLink,
    required this.onDelete,
  });

  final SubscriptionInfo info;
  final NikoStrings strings;
  final VoidCallback? onUpdate;
  final VoidCallback onSettings;
  final VoidCallback? onCopyLink;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final when = info.lastUpdated > 0
        ? strings.subscriptionUpdated(formatMoment(DateTime.fromMillisecondsSinceEpoch(info.lastUpdated * 1000)))
        : strings.subscriptionNever;
    final usage = subscriptionUsage(info, strings);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(usage.isEmpty ? when : '$usage · $when',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: NikoType.bodySm.style(colors.ink2)),
        if (info.announce.isNotEmpty)
          Text(info.announce, maxLines: 2, overflow: TextOverflow.ellipsis, style: NikoType.bodySm.style(colors.ink2)),
        const SizedBox(height: NikoSpace.s2),
        Wrap(
          spacing: NikoSpace.s2,
          runSpacing: NikoSpace.s2,
          children: [
            NikoTonalButton(
              label: info.updating ? strings.subscriptionUpdating : strings.subscriptionUpdate,
              onPressed: onUpdate,
            ),
            NikoGhostButton(label: strings.subscriptionSettings, onPressed: onSettings),
            if (onCopyLink != null) NikoGhostButton(label: strings.subscriptionCopyLink, onPressed: onCopyLink),
            NikoGhostButton(label: strings.subscriptionDelete, onPressed: onDelete),
          ],
        ),
      ],
    );
  }
}

/// The panel of groups (m-list with its title): the one shown on surface-2.
class _Groups extends StatelessWidget {
  const _Groups({
    required this.feed,
    required this.strings,
    required this.onAdd,
    required this.onNewGroup,
    required this.onUpdateAll,
    required this.onChoose,
    required this.scrollable,
  });

  final ProfilesFeed feed;
  final NikoStrings strings;
  final VoidCallback? onAdd;
  final VoidCallback? onNewGroup;
  final VoidCallback? onUpdateAll;
  final ValueChanged<int> onChoose;
  final bool scrollable;

  Widget _row(GroupRow g) => _GroupRow(
        key: ValueKey(g.id),
        name: groupName(g, strings),
        sub: g.ungrouped
            ? strings.groupOwnSub(g.profiles)
            : g.nodeId.isNotEmpty
                ? [
                    strings.groupNodeSub(g.profiles),
                    if (feed.nodeOfGroup(g.id) case final node?) nodeUsage(node, strings),
                  ].where((part) => part.isNotEmpty).join(' · ')
                : g.subscription
                    ? [
                        strings.groupSubscriptionSub(g.profiles),
                        if (g.info case final info?) subscriptionUsage(info, strings),
                      ].where((part) => part.isNotEmpty).join(' · ')
                    : strings.groupBasicSub(g.profiles),
        chosen: g.id == feed.groupId,
        onPressed: () => onChoose(g.id),
      );

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(NikoRadius.md),
      child: ColoredBox(
        color: colors.surface1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(NikoSpace.s5, NikoSpace.s3, NikoSpace.s3, NikoSpace.s1),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(header: true, child: Text(strings.groups, style: NikoType.headline.style(colors.ink))),
                  ),
                  NikoIconButton(icon: NikoIcons.plus, label: strings.add, tonal: true, onPressed: onAdd),
                ],
              ),
            ),
            if (onNewGroup != null || onUpdateAll != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(NikoSpace.s4, 0, NikoSpace.s3, NikoSpace.s2),
                child: Wrap(
                  spacing: NikoSpace.s2,
                  runSpacing: NikoSpace.s1,
                  children: [
                    if (onNewGroup != null) NikoGhostButton(label: strings.groupNew, onPressed: onNewGroup),
                    if (onUpdateAll != null) NikoGhostButton(label: strings.subscriptionsUpdateAll, onPressed: onUpdateAll),
                  ],
                ),
              ),
            if (scrollable)
              Flexible(
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: feed.groups.length,
                  itemBuilder: (context, i) => _row(feed.groups[i]),
                ),
              )
            else
              for (final g in feed.groups) _row(g),
            const SizedBox(height: NikoSpace.s2),
          ],
        ),
      ),
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({super.key, required this.name, required this.sub, required this.chosen, required this.onPressed});

  final String name;
  final String sub;
  final bool chosen;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    return Semantics(
      selected: chosen,
      button: true,
      label: '$name, $sub',
      excludeSemantics: true,
      child: NikoPressable(
        radius: 0,
        onPressed: onPressed,
        builder: (context, state) => ColoredBox(
          color: chosen || state.pressed ? colors.surface2 : const Color(0x00000000),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: NikoSpace.s5, vertical: NikoSpace.s3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NikoType.body.style(colors.ink, weight: chosen ? FontWeight.w600 : null)),
                Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: NikoType.bodySm.style(colors.ink2)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The label of a bean's type in a row's tag: the app's names, VMess's bean holding VLESS too.
String typeLabel(String type) => switch (type) {
      'vmess' => 'V2Ray',
      'ss' => 'Shadowsocks',
      'socks' => 'SOCKS',
      'hysteria' => 'Hysteria',
      'trojan' => 'Trojan',
      'trojan_go' => 'Trojan-Go',
      'naive' => 'naive',
      'tuic' => 'TUIC',
      'anytls' => 'AnyTLS',
      'mieru' => 'Mieru',
      'http' => 'HTTP',
      _ => type,
    };

/// A profile as a row (m-row): radio, name, type/address, optional latency badge, edit, share, delete.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    super.key,
    required this.profile,
    required this.selected,
    required this.divider,
    this.latency,
    required this.onPressed,
    this.onEdit,
    required this.onDelete,
    this.onShare,
  });

  final ProfileRow profile;
  final bool selected;
  final bool divider;
  final ProfileTestEntry? latency;
  final VoidCallback onPressed;
  final VoidCallback? onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final strings = NikoStrings.of(Localizations.localeOf(context));
    final body = Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      label: '${profile.name}, ${typeLabel(profile.type)}, ${profile.address}',
      excludeSemantics: true,
      child: NikoPressable(
        radius: 0,
        onPressed: onPressed,
        builder: (context, state) => ColoredBox(
          color: state.pressed ? colors.surface2 : const Color(0x00000000),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(NikoSpace.s4, NikoSpace.s3, NikoSpace.s2, NikoSpace.s3),
              child: Row(
                children: [
                  NikoRadio(on: selected),
                  const SizedBox(width: NikoSpace.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(profile.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NikoType.body.style(colors.ink, weight: selected ? FontWeight.w600 : null)),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            NikoTag(typeLabel(profile.type)),
                            const SizedBox(width: NikoSpace.s2),
                            Flexible(
                              child: Text(profile.address,
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: NikoType.code.style(colors.ink2)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return CustomPaint(
      foregroundPainter: divider ? _Hairline(colors.line) : null,
      child: Row(
        children: [
          Expanded(child: body),
          if (latency case final lat?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: NikoSpace.s2),
              child: Text(
                lat.ok ? '${lat.latencyMs} ms' : 'ERR',
                style: NikoType.code.style(lat.ok ? colors.ink : colors.danger),
              ),
            ),
          if (onEdit != null)
            NikoGhostButton(label: strings.profileEdit, onPressed: onEdit),
          if (onShare != null)
            NikoIconButton(
              icon: NikoIcons.copy,
              label: strings.profileShare(profile.name),
              muted: true,
              small: true,
              onPressed: onShare,
            ),
          Padding(
            padding: const EdgeInsets.only(right: NikoSpace.s2),
            child: NikoIconButton(
              icon: NikoIcons.trash,
              label: strings.profileDelete(profile.name),
              muted: true,
              small: true,
              onPressed: onDelete,
            ),
          ),
        ],
      ),
    );
  }
}

/// m-snackbar: what was done, on surface-3, and the way back where there is one.
class _Snackbar extends StatelessWidget {
  const _Snackbar({required this.text, this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: DecoratedBox(
            decoration: BoxDecoration(color: colors.surface3, borderRadius: BorderRadius.circular(NikoRadius.md)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(NikoSpace.s4, NikoSpace.s1, NikoSpace.s1, NikoSpace.s1),
              child: Row(
                children: [
                  Expanded(child: Text(text, maxLines: 2, style: NikoType.bodySm.style(colors.ink))),
                  if (action case final label?)
                    NikoGhostButton(label: label, onPressed: onAction)
                  else
                    const SizedBox(height: NikoSize.control),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Hairline extends CustomPainter {
  _Hairline(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawRect(Rect.fromLTWH(NikoSpace.s4, 0, size.width - NikoSpace.s4, NikoStroke.hairline), Paint()..color = color);

  @override
  bool shouldRepaint(_Hairline oldDelegate) => color != oldDelegate.color;
}

/// Puts text on the system clipboard.
Future<void> copyText(String text) => Clipboard.setData(ClipboardData(text: text));
