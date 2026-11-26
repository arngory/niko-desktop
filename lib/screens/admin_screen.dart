import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';

import '../daemon/daemon.dart';
import '../l10n/strings.dart';
import '../theme/niko_theme.dart';
import '../ui/banner.dart';
import '../ui/controls.dart';
import '../ui/fields.dart';
import '../ui/format.dart';
import '../ui/icons.dart';
import '../ui/list.dart';

enum _AdminTab { status, users, services, audit }

/// Admin panel for a raycontrol node (D-ADMIN), proxied via NikoService.NodeAdminCall
/// so client private keys never leave the daemon.
class AdminScreen extends StatefulWidget {
  const AdminScreen({
    super.key,
    required this.daemon,
    required this.node,
    required this.onBack,
  });

  final Daemon daemon;
  final NodeRow node;
  final VoidCallback onBack;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  _AdminTab _tab = _AdminTab.status;
  int _calls = 0;
  bool get _busy => _calls > 0;
  String _error = '';
  String _notice = '';

  Map<String, dynamic>? _status;
  List<Map<String, dynamic>> _users = const [];
  String? _selectedUser;
  List<Map<String, dynamic>> _devices = const [];
  List<Map<String, dynamic>> _services = const [];
  List<Map<String, dynamic>> _audit = const [];

  bool _creatingInvite = false;
  final _inviteUser = TextEditingController();
  final _inviteDevice = TextEditingController(text: 'desktop');
  bool _inviteRequirePin = false;
  final _inviteTtl = TextEditingController(text: '24');
  String _inviteRole = 'user';
  String _createdInvite = '';
  String _createdInvitePin = '';

  String? _revokingDeviceId;
  String _revokingDeviceName = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadTab());
  }

  @override
  void dispose() {
    _inviteUser.dispose();
    _inviteDevice.dispose();
    _inviteTtl.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(String method, [Map<String, Object?> body = const {}]) async {
    final raw = await widget.daemon.nodeAdminCall(widget.node.id, method, bodyJson: jsonEncode(body));
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _calls++;
      _error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = daemonError(e));
    } finally {
      if (mounted) setState(() => _calls = (_calls - 1).clamp(0, 1 << 20));
    }
  }

  Future<void> _loadTab() => _run(() async {
        switch (_tab) {
          case _AdminTab.status:
            _status = await _call('GetStatus');
          case _AdminTab.users:
            final res = await _call('ListUsers');
            _users = _listOfMaps(res['users']);
            if (_selectedUser != null) {
              await _loadDevicesInner(_selectedUser!);
            }
          case _AdminTab.services:
            final res = await _call('ListServices');
            _services = _listOfMaps(res['services']);
          case _AdminTab.audit:
            final res = await _call('ListAudit', {'limit': 50});
            _audit = _listOfMaps(res['entries']);
        }
      });

  Future<void> _loadDevicesInner(String user) async {
    final res = await _call('ListDevices', {'user': user});
    _devices = _listOfMaps(res['devices']);
  }

  Future<void> _selectUser(String user) => _run(() async {
        _selectedUser = user;
        _inviteUser.text = user;
        _revokingDeviceId = null;
        await _loadDevicesInner(user);
      });

  Future<void> _submitInvite(NikoStrings strings) => _run(() async {
        final user = _inviteUser.text.trim();
        final deviceName = _inviteDevice.text.trim().isEmpty ? 'desktop' : _inviteDevice.text.trim();
        final hours = int.tryParse(_inviteTtl.text.trim()) ?? 24;
        final body = <String, Object?>{
          if (user.isNotEmpty) 'user': user,
          'name': deviceName,
          'role': _inviteRole,
          'ttlSeconds': '${hours.clamp(1, 24 * 30) * 3600}',
          if (_inviteRequirePin) 'pin': true,
        };
        final res = await _call('CreateInvite', body);
        final inv = _str(res['inviteCodeShort']).isNotEmpty
            ? _str(res['inviteCodeShort'])
            : _str(res['inviteCode']).isNotEmpty
                ? _str(res['inviteCode'])
                : _str(res['invite']);
        _createdInvite = inv;
        _createdInvitePin = _str(res['pin']);
        _creatingInvite = false;
        _notice = strings.adminInviteCreated;
        if (_selectedUser != null) {
          await _loadDevicesInner(_selectedUser!);
        }
      });

  Future<void> _revokeConfirmed() => _run(() async {
        final id = _revokingDeviceId;
        if (id == null) return;
        await _call('RevokeDevice', {'id': id});
        _revokingDeviceId = null;
        if (_selectedUser != null) {
          await _loadDevicesInner(_selectedUser!);
        }
      });

  Future<void> _renewUser(String user) => _run(() async {
        await _call('RenewUser', {'name': user});
        _notice = '$user: renewed';
      });

  Future<void> _toggleService(String name, bool enable) => _run(() async {
        await _call('SetServiceEnabled', {'name': name, 'enabled': enable});
        final res = await _call('ListServices');
        _services = _listOfMaps(res['services']);
      });

  Future<void> _rotateService(String name) => _run(() async {
        await _call('RotateService', {'name': name});
        _notice = '$name rotated';
      });

  static List<Map<String, dynamic>> _listOfMaps(Object? raw) {
    if (raw is! List) return const [];
    return [for (final item in raw) if (item is Map<String, dynamic>) item];
  }

  static String _str(Object? v) => v == null ? '' : '$v';
  static int _num(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final strings = NikoStrings.of(Localizations.localeOf(context));

    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
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
                        '${strings.adminTitle} · ${widget.node.name}',
                        style: NikoType.title.style(colors.ink),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    NikoTonalButton(
                      label: strings.adminRefresh,
                      onPressed: _busy ? null : () => unawaited(_loadTab()),
                    ),
                  ],
                ),
                const SizedBox(height: NikoSpace.s4),
                Wrap(
                  spacing: NikoSpace.s2,
                  runSpacing: NikoSpace.s2,
                  children: [
                    for (final (tab, label) in [
                      (_AdminTab.status, strings.adminTabStatus),
                      (_AdminTab.users, strings.adminTabUsers),
                      (_AdminTab.services, strings.adminTabServices),
                      (_AdminTab.audit, strings.adminTabAudit),
                    ])
                      tab == _tab
                          ? NikoTonalButton(label: label, onPressed: () {})
                          : NikoGhostButton(
                              label: label,
                              onPressed: () {
                                setState(() {
                                  _tab = tab;
                                  _error = '';
                                  _notice = '';
                                });
                                unawaited(_loadTab());
                              },
                            ),
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
                const SizedBox(height: NikoSpace.s5),
                ...switch (_tab) {
                  _AdminTab.status => _buildStatus(strings),
                  _AdminTab.users => _buildUsers(strings),
                  _AdminTab.services => _buildServices(strings),
                  _AdminTab.audit => _buildAudit(strings),
                },
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildStatus(NikoStrings strings) {
    final st = _status;
    if (st == null) return [NikoBanner(icon: NikoIcons.rotateCw, title: strings.adminNoItems)];
    final warnings = (st['warnings'] is List) ? (st['warnings'] as List).map(_str).where((s) => s.isNotEmpty).toList() : const <String>[];
    final host = _str(st['host']).isNotEmpty ? _str(st['host']) : _str(st['hostname']);
    return [
      NikoSection(
        overline: strings.adminTabStatus,
        rows: [
          NikoInfoRow(title: strings.adminVersion, value: _str(st['version']).isEmpty ? '—' : _str(st['version'])),
          if (host.isNotEmpty) NikoInfoRow(title: 'Host', value: host),
          if (_num(st['uptimeSeconds']) > 0)
            NikoInfoRow(title: 'Uptime', value: formatElapsed(Duration(seconds: _num(st['uptimeSeconds'])))),
        ],
      ),
      if (warnings.isNotEmpty) ...[
        const SizedBox(height: NikoSpace.s4),
        for (final w in warnings) ...[
          NikoBanner(icon: NikoIcons.alert, title: strings.adminWarnings, text: w),
          const SizedBox(height: NikoSpace.s2),
        ],
      ],
    ];
  }

  List<Widget> _buildUsers(NikoStrings strings) {
    final colors = NikoTheme.of(context);
    return [
      Wrap(
        spacing: NikoSpace.s3,
        runSpacing: NikoSpace.s2,
        children: [
          NikoPrimaryButton(
            label: strings.adminCreateInvite,
            onPressed: _busy
                ? null
                : () => setState(() {
                      _creatingInvite = !_creatingInvite;
                      _createdInvite = '';
                      _createdInvitePin = '';
                    }),
          ),
        ],
      ),
      if (_createdInvite.isNotEmpty) ...[
        const SizedBox(height: NikoSpace.s4),
        NikoBanner(
          icon: NikoIcons.copy,
          title: strings.adminInviteCreated,
          text: _createdInvitePin.isNotEmpty ? '$_createdInvite\nPIN: $_createdInvitePin' : _createdInvite,
          action: strings.adminCopyInvite,
          onAction: () => unawaited(
            Clipboard.setData(ClipboardData(text: _createdInvite)).then((_) {
              if (mounted) setState(() => _notice = strings.adminInviteCopied);
            }),
          ),
        ),
      ],
      if (_creatingInvite) ...[
        const SizedBox(height: NikoSpace.s4),
        NikoTextField(controller: _inviteUser, label: strings.adminInviteUser),
        const SizedBox(height: NikoSpace.s3),
        NikoTextField(controller: _inviteDevice, label: strings.adminInviteDevice),
        const SizedBox(height: NikoSpace.s3),
        NikoSegmented<String>(
          label: strings.adminInviteRole,
          choices: const [('user', 'user'), ('admin', 'admin')],
          value: _inviteRole,
          onChanged: (r) => setState(() => _inviteRole = r),
        ),
        const SizedBox(height: NikoSpace.s3),
        NikoSwitchRow(
          title: strings.adminInvitePin,
          on: _inviteRequirePin,
          divider: false,
          onChanged: (v) => setState(() => _inviteRequirePin = v),
        ),
        const SizedBox(height: NikoSpace.s3),
        NikoTextField(controller: _inviteTtl, label: strings.adminInviteTtl),
        const SizedBox(height: NikoSpace.s3),
        Row(
          children: [
            NikoPrimaryButton(label: strings.ruleSave, onPressed: _busy ? null : () => unawaited(_submitInvite(strings))),
            const SizedBox(width: NikoSpace.s3),
            NikoGhostButton(label: strings.cancel, onPressed: () => setState(() => _creatingInvite = false)),
          ],
        ),
      ],
      const SizedBox(height: NikoSpace.s5),
      if (_users.isEmpty)
        NikoBanner(icon: NikoIcons.alert, title: strings.adminNoItems)
      else
        NikoSection(
          overline: strings.adminTabUsers,
          rows: [
            for (var i = 0; i < _users.length; i++) ...[
              NikoLinkRow(
                title: _str(_users[i]['name']),
                value: [
                  if (_num(_users[i]['trafficUsed']) > 0) formatBytes(_num(_users[i]['trafficUsed'])),
                  if (_num(_users[i]['trafficLimit']) > 0) '/ ${formatBytes(_num(_users[i]['trafficLimit']))}',
                ].join(' '),
                divider: i > 0,
                onPressed: () => unawaited(_selectUser(_str(_users[i]['name']))),
              ),
            ],
          ],
        ),
      if (_selectedUser != null) ...[
        const SizedBox(height: NikoSpace.s5),
        Row(
          children: [
            Expanded(
              child: Text('${strings.adminDevices} · $_selectedUser', style: NikoType.headline.style(colors.ink)),
            ),
            NikoTonalButton(
              label: strings.adminRenewUser,
              onPressed: _busy ? null : () => unawaited(_renewUser(_selectedUser!)),
            ),
          ],
        ),
        const SizedBox(height: NikoSpace.s3),
        if (_revokingDeviceId != null) ...[
          NikoBanner(
            icon: NikoIcons.trash,
            title: strings.adminRevokeConfirm(_revokingDeviceName),
            danger: true,
            action: strings.adminRevoke,
            onAction: _busy ? null : () => unawaited(_revokeConfirmed()),
          ),
          const SizedBox(height: NikoSpace.s2),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: NikoGhostButton(label: strings.cancel, onPressed: () => setState(() => _revokingDeviceId = null)),
          ),
          const SizedBox(height: NikoSpace.s3),
        ],
        if (_devices.isEmpty)
          NikoBanner(icon: NikoIcons.alert, title: strings.adminNoItems)
        else
          NikoSection(
            overline: strings.adminDevices,
            rows: [
              for (final d in _devices)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: NikoSpace.s4, vertical: NikoSpace.s3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_str(d['name']).isEmpty ? _str(d['id']) : _str(d['name']), style: NikoType.body.style(colors.ink)),
                            Text('${_str(d['role'])} · ${_str(d['id'])}', style: NikoType.code.style(colors.ink2)),
                          ],
                        ),
                      ),
                      NikoGhostButton(
                        label: strings.adminRevoke,
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _revokingDeviceId = _str(d['id']);
                                  _revokingDeviceName = _str(d['name']).isEmpty ? _str(d['id']) : _str(d['name']);
                                }),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    ];
  }

  List<Widget> _buildServices(NikoStrings strings) {
    final colors = NikoTheme.of(context);
    if (_services.isEmpty) return [NikoBanner(icon: NikoIcons.alert, title: strings.adminNoItems)];
    return [
      NikoSection(
        overline: strings.adminTabServices,
        rows: [
          for (final svc in _services)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: NikoSpace.s4, vertical: NikoSpace.s3),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_str(svc['name']), style: NikoType.body.style(colors.ink)),
                        Text('${_str(svc['kind'])} · port ${_num(svc['port'])}', style: NikoType.code.style(colors.ink2)),
                      ],
                    ),
                  ),
                  NikoGhostButton(
                    label: svc['enabled'] == true ? strings.adminDisable : strings.adminEnable,
                    onPressed: _busy ? null : () => unawaited(_toggleService(_str(svc['name']), svc['enabled'] != true)),
                  ),
                  const SizedBox(width: NikoSpace.s2),
                  NikoTonalButton(
                    label: strings.adminRotateService,
                    onPressed: _busy ? null : () => unawaited(_rotateService(_str(svc['name']))),
                  ),
                ],
              ),
            ),
        ],
      ),
    ];
  }

  List<Widget> _buildAudit(NikoStrings strings) {
    if (_audit.isEmpty) return [NikoBanner(icon: NikoIcons.alert, title: strings.adminNoItems)];
    return [
      NikoSection(
        overline: strings.adminTabAudit,
        rows: [
          for (final e in _audit)
            NikoInfoRow(
              title: '${_str(e['action'])} ${_str(e['target'])}'.trim(),
              value: '${_str(e['actor'])} · ${_str(e['result'])}',
            ),
        ],
      ),
    ];
  }
}
