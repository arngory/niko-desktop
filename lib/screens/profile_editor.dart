import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../l10n/strings.dart';
import '../theme/niko_theme.dart';
import '../ui/banner.dart';
import '../ui/controls.dart';
import '../ui/fields.dart';
import '../ui/icons.dart';

/// Manual profile editor (D-PROFILE-01..05): supports common proxy protocols with structured fields
/// plus a raw bean JSON mode for full access to protocol-specific options.
class ProfileEditor extends StatefulWidget {
  const ProfileEditor({
    super.key,
    required this.strings,
    this.profileId = 0,
    this.groupId = 0,
    this.initialType = 'socks',
    this.initialBeanJson = '',
    required this.onSave,
    required this.onCancel,
  });

  final NikoStrings strings;
  final int profileId;
  final int groupId;
  final String initialType;
  final String initialBeanJson;
  final Future<String?> Function({required int id, required int groupId, required String type, required String beanJson}) onSave;
  final VoidCallback onCancel;

  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

const _profileTypes = <(String, String)>[
  ('socks', 'SOCKS5'),
  ('http', 'HTTP'),
  ('vmess', 'VLESS / VMess'),
  ('trojan', 'Trojan'),
  ('ss', 'Shadowsocks'),
  ('hysteria', 'Hysteria'),
  ('naive', 'naive'),
  ('tuic', 'TUIC'),
  ('anytls', 'AnyTLS'),
];

class _ProfileEditorState extends State<ProfileEditor> {
  late String _type = widget.initialType.isEmpty ? 'socks' : widget.initialType;
  bool _rawMode = false;
  late String _name;
  late String _server;
  late String _port;
  late String _username;
  late String _password;
  late String _sni;
  late String _rawJson;
  Map<String, Object?> _baseBean = {};
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = '';
    _server = '';
    _port = '443';
    _username = '';
    _password = '';
    _sni = '';
    _rawJson = widget.initialBeanJson;
    if (widget.initialBeanJson.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(widget.initialBeanJson);
        if (decoded is Map) {
          _baseBean = {for (final e in decoded.entries) '${e.key}': e.value};
          _name = '${_baseBean['name'] ?? ''}';
          _server = '${_baseBean['serverAddress'] ?? ''}';
          final p = _baseBean['serverPort'];
          if (p != null) _port = '$p';
          _username = '${_baseBean['username'] ?? ''}';
          _password = '${_baseBean['password'] ?? _baseBean['uuid'] ?? _baseBean['authPayload'] ?? _baseBean['token'] ?? ''}';
          _sni = '${_baseBean['sni'] ?? ''}';
        }
      } catch (_) {
        _rawMode = true;
      }
    }
  }

  String _composeBeanJson() {
    if (_rawMode) return _rawJson.trim();
    final port = int.tryParse(_port.trim()) ?? 0;
    final bean = <String, Object?>{
      ..._baseBean,
      'name': _name.trim(),
      'serverAddress': _server.trim(),
      'serverPort': port,
    };
    switch (_type) {
      case 'socks' || 'http':
        bean['username'] = _username;
        bean['password'] = _password;
      case 'vmess':
        bean['uuid'] = _password;
        if (_sni.trim().isNotEmpty) bean['sni'] = _sni.trim();
      case 'hysteria':
        bean['authPayload'] = _password;
        if (_sni.trim().isNotEmpty) bean['sni'] = _sni.trim();
      case 'tuic':
        bean['uuid'] = _username;
        bean['token'] = _password;
        if (_sni.trim().isNotEmpty) bean['sni'] = _sni.trim();
      case 'naive':
        bean['username'] = _username;
        bean['password'] = _password;
        if (_sni.trim().isNotEmpty) bean['sni'] = _sni.trim();
      default:
        bean['password'] = _password;
        if (_sni.trim().isNotEmpty) bean['sni'] = _sni.trim();
    }
    return const JsonEncoder.withIndent('  ').convert(bean);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await widget.onSave(
      id: widget.profileId,
      groupId: widget.groupId,
      type: _type,
      beanJson: _composeBeanJson(),
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = NikoTheme.of(context);
    final strings = widget.strings;
    final editing = widget.profileId > 0;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 616),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(NikoSpace.s8, NikoSpace.s6, NikoSpace.s8, NikoSpace.s8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(editing ? strings.profileEdit : strings.profileNew, style: NikoType.title.style(colors.ink)),
              ),
              const SizedBox(height: NikoSpace.s4),
              if (!editing) ...[
                Text(strings.profileType, style: NikoType.bodySm.style(colors.ink2)),
                const SizedBox(height: NikoSpace.s2),
                Wrap(
                  spacing: NikoSpace.s2,
                  runSpacing: NikoSpace.s2,
                  children: [
                    for (final (code, label) in _profileTypes)
                      _type == code
                          ? NikoPrimaryButton(label: label, onPressed: () {})
                          : NikoTonalButton(label: label, onPressed: () => setState(() => _type = code)),
                  ],
                ),
                const SizedBox(height: NikoSpace.s4),
              ],
              Row(
                children: [
                  NikoSwitch(
                    on: _rawMode,
                  ),
                  const SizedBox(width: NikoSpace.s3),
                  NikoGhostButton(
                    label: strings.profileRawJson,
                    onPressed: () => setState(() {
                      if (!_rawMode) {
                        _rawJson = _composeBeanJson();
                        _rawMode = true;
                      } else {
                        _rawMode = false;
                      }
                    }),
                  ),
                ],
              ),
              const SizedBox(height: NikoSpace.s4),
              if (_rawMode)
                NikoField(
                  label: strings.profileRawJson,
                  value: _rawJson,
                  input: FieldInput.lines,
                  mono: true,
                  onChanged: (v) => setState(() => _rawJson = v),
                )
              else ...[
                NikoField(label: strings.profileName, value: _name, onChanged: (v) => setState(() => _name = v)),
                const SizedBox(height: NikoSpace.s3),
                NikoField(
                  label: strings.profileServer,
                  value: _server,
                  mono: true,
                  onChanged: (v) => setState(() => _server = v),
                ),
                const SizedBox(height: NikoSpace.s3),
                NikoField(
                  label: strings.profilePort,
                  value: _port,
                  input: FieldInput.port,
                  mono: true,
                  onChanged: (v) => setState(() => _port = v),
                ),
                const SizedBox(height: NikoSpace.s3),
                NikoField(
                  label: strings.profileUsername,
                  value: _username,
                  mono: true,
                  onChanged: (v) => setState(() => _username = v),
                ),
                const SizedBox(height: NikoSpace.s3),
                NikoField(
                  label: strings.profilePassword,
                  value: _password,
                  input: FieldInput.secret,
                  mono: true,
                  onChanged: (v) => setState(() => _password = v),
                ),
                const SizedBox(height: NikoSpace.s3),
                NikoField(
                  label: strings.profileSni,
                  value: _sni,
                  mono: true,
                  onChanged: (v) => setState(() => _sni = v),
                ),
              ],
              if (_error != null && _error!.isNotEmpty) ...[
                const SizedBox(height: NikoSpace.s4),
                NikoBanner(icon: NikoIcons.alert, title: strings.saveFailed, text: _error!, danger: true),
              ],
              const SizedBox(height: NikoSpace.s6),
              Row(
                children: [
                  NikoPrimaryButton(label: strings.save, onPressed: _saving ? null : _save),
                  const SizedBox(width: NikoSpace.s3),
                  NikoGhostButton(label: strings.cancel, onPressed: widget.onCancel),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
