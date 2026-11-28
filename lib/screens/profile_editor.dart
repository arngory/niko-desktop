import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../daemon/daemon.dart';
import '../l10n/strings.dart';
import '../theme/niko_theme.dart';
import '../ui/banner.dart';
import '../ui/controls.dart';
import '../ui/fields.dart';
import '../ui/icons.dart';

/// Spec-driven manual profile editor (D-PROFILE-01..03): supports all desktop protocols with
/// protocol-specific structured fields, fine-tuning (`AbstractBean`: certPins, tlsFragment,
/// DNS tunnel, port knocking, UDP desync, Yggdrasil peer), raw JSON round-trip, and `CheckProfile`.
class ProfileEditor extends StatefulWidget {
  const ProfileEditor({
    super.key,
    required this.strings,
    this.profileId = 0,
    this.groupId = 0,
    this.initialType = 'vless',
    this.initialBeanJson = '',
    this.availableProfiles = const [],
    this.onCheck,
    required this.onSave,
    required this.onCancel,
  });

  final NikoStrings strings;
  final int profileId;
  final int groupId;
  final String initialType;
  final String initialBeanJson;
  final List<ProfileRow> availableProfiles;
  final Future<ProfileCheckResult> Function({required String type, required String beanJson})? onCheck;
  final Future<String?> Function({required int id, required int groupId, required String type, required String beanJson})
      onSave;
  final VoidCallback onCancel;

  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

const _profileTypes = <(String, String)>[
  ('vless', 'VLESS'),
  ('hysteria', 'Hysteria2'),
  ('naive', 'naive'),
  ('vmess', 'VMess'),
  ('trojan', 'Trojan'),
  ('trojan-go', 'Trojan-Go'),
  ('ss', 'Shadowsocks'),
  ('tuic', 'TUIC'),
  ('anytls', 'AnyTLS'),
  ('wg', 'WireGuard'),
  ('mieru', 'Mieru'),
  ('ssh', 'SSH'),
  ('socks', 'SOCKS5'),
  ('http', 'HTTP'),
  ('chain', 'Chain'),
];

class _ProfileEditorState extends State<ProfileEditor> {
  late String _type;
  bool _rawMode = false;
  bool _showTuning = false;

  // Common fields
  String _name = '';
  String _server = '';
  String _port = '443';
  String _username = '';
  String _password = '';
  String _sni = '';

  // VLESS / VMess / Trojan / AnyTLS / TUIC fields
  String _security = 'tls';
  String _transport = 'tcp';
  String _host = '';
  String _path = '';
  String _flow = '';
  String _utlsFingerprint = 'chrome';
  String _realityPubKey = '';
  String _realityShortId = '';
  String _vlessEncryption = '';
  String _xhttpMode = 'auto';
  String _alpn = '';
  bool _allowInsecure = false;

  // Hysteria2 fields
  String _obfs = '';
  String _upMbps = '';
  String _downMbps = '';
  String _hopInterval = '';

  // naive fields
  String _naiveProto = 'https';
  bool _sUoT = false;
  bool _nikoUdp = false;
  bool _nikoAck = false;
  bool _nikoIcmp = false;
  String _naiveExtraHeaders = '';
  String _naiveInsecureConcurrency = '';
  String _naiveCertificates = '';

  // ChainBean hops (D-PROFILE-04)
  List<int> _chainProxies = [];

  // TUIC fields
  String _congestionControl = 'bbr';
  String _udpRelayMode = 'native';

  // WireGuard / AmneziaWG fields
  String _localAddress = '10.0.0.2/32';
  String _preSharedKey = '';
  String _mtu = '1420';
  String _amneziaWg = '';

  // Mieru fields
  String _mieruProto = 'TCP';

  // Fine-tuning (D-PROFILE-03: AbstractBean)
  String _certPins = '';
  String _tlsFragment = '';
  String _dnsTunnel = '';
  String _dnsTunnelDomain = '';
  String _dnsTunnelResolver = '';
  String _dnsTunnelKey = '';
  String _dnsTunnelSeal = '';
  String _dnsTunnelTls = '';
  String _dnsTunnelAuth = '';
  String _dnsTunnelMethod = '';
  bool _dnsTunnelFixedUpstream = false;
  String _dnsTunnelSpare = '';
  String _knockSequence = '';
  String _udpPrelude = '';
  String _udpPreludeSni = '';
  String _udpPreludeTtl = '';
  bool _udpReorderInitial = false;
  String _yggPeer = '';

  String _rawJson = '';
  Map<String, Object?> _baseBean = {};
  String? _error;
  ProfileCheckResult? _checkResult;
  bool _checking = false;
  bool _saving = false;

  static final Set<String> _structuredTypeCodes = {for (final (code, _) in _profileTypes) code};

  @override
  void initState() {
    super.initState();
    _type = widget.initialType.isEmpty ? 'vless' : widget.initialType;
    _rawJson = widget.initialBeanJson;
    if (widget.initialBeanJson.trim().isNotEmpty) {
      if (!_loadFromJson(widget.initialBeanJson)) {
        _rawMode = true;
      }
    }
    if (!_structuredTypeCodes.contains(_type)) {
      _rawMode = true;
    }
  }

  String _s(Map<String, Object?> m, String key, [String fallback = '']) {
    final v = m[key];
    return v == null ? fallback : '$v';
  }

  bool _loadFromJson(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) return false;
      final bean = {for (final e in decoded.entries) '${e.key}': e.value};
      _baseBean = bean;
      if (_type == 'vmess' && bean['alterId'] == -1) {
        _type = 'vless';
      }
      _name = _s(bean, 'name');
      _server = _s(bean, 'serverAddress');
      if (_type == 'hysteria') {
        final ports = _s(bean, 'serverPorts').trim();
        _port = ports.isNotEmpty ? ports : _s(bean, 'serverPort', '443');
      } else {
        _port = _s(bean, 'serverPort', '443');
      }
      _username = _s(bean, 'username', _s(bean, 'method', _s(bean, 'peerPublicKey')));
      _password = _s(
        bean,
        'password',
        _s(bean, 'uuid', _s(bean, 'authPayload', _s(bean, 'token', _s(bean, 'privateKey')))),
      );
      if (_type == 'tuic') {
        _username = _s(bean, 'uuid');
        _password = _s(bean, 'token');
      }
      _sni = _s(bean, 'sni');
      _security = _s(bean, 'security', 'tls');
      _transport = _s(bean, 'type', 'tcp');
      _host = _s(bean, 'host');
      _path = _s(bean, 'path');
      _flow = _s(bean, 'encryption');
      _utlsFingerprint = _s(bean, 'utlsFingerprint', 'chrome');
      _realityPubKey = _s(bean, 'realityPubKey');
      _realityShortId = _s(bean, 'realityShortId');
      _vlessEncryption = _s(bean, 'vlessEncryption');
      _xhttpMode = _s(bean, 'xhttpMode', 'auto');
      _alpn = _s(bean, 'alpn');
      _allowInsecure = bean['allowInsecure'] == true;
      _obfs = _s(bean, 'obfuscation');
      _upMbps = bean['uploadMbps'] != null && bean['uploadMbps'] != 0 ? '${bean['uploadMbps']}' : '';
      _downMbps = bean['downloadMbps'] != null && bean['downloadMbps'] != 0 ? '${bean['downloadMbps']}' : '';
      _hopInterval = bean['hopInterval'] != null && bean['hopInterval'] != 0 ? '${bean['hopInterval']}' : '';
      _naiveProto = _s(bean, 'proto', 'https');
      _sUoT = bean['sUoT'] == true;
      _nikoUdp = bean['nikoUdp'] == true;
      _nikoAck = bean['nikoAck'] == true;
      _nikoIcmp = bean['nikoIcmp'] == true;
      _naiveExtraHeaders = _s(bean, 'extraHeaders');
      _naiveInsecureConcurrency =
          bean['insecureConcurrency'] != null && bean['insecureConcurrency'] != 0 ? '${bean['insecureConcurrency']}' : '';
      _naiveCertificates = _s(bean, 'certificates');
      if (bean['proxies'] is List) {
        _chainProxies = [
          for (final item in bean['proxies'] as List)
            if (item is num) item.toInt(),
        ];
      } else {
        _chainProxies = [];
      }
      _congestionControl = _s(bean, 'congestionController', 'bbr');
      _udpRelayMode = _s(bean, 'udpRelayMode', 'native');
      _localAddress = _s(bean, 'localAddress', '10.0.0.2/32');
      _preSharedKey = _s(bean, 'peerPreSharedKey');
      _mtu = bean['mtu'] != null ? '${bean['mtu']}' : '1420';
      _amneziaWg = _s(bean, 'amneziaWG');
      _mieruProto = _s(bean, 'protocol', 'TCP');

      // AbstractBean fine-tuning
      _certPins = _s(bean, 'certPins');
      _tlsFragment = bean['tlsFragment'] != null && bean['tlsFragment'] != 0 ? '${bean['tlsFragment']}' : '';
      _dnsTunnel = _s(bean, 'dnsTunnel');
      _dnsTunnelDomain = _s(bean, 'dnsTunnelDomain');
      _dnsTunnelResolver = _s(bean, 'dnsTunnelResolver');
      _dnsTunnelKey = _s(bean, 'dnsTunnelKey');
      _dnsTunnelSeal = _s(bean, 'dnsTunnelSeal');
      _dnsTunnelTls = _s(bean, 'dnsTunnelTls');
      _dnsTunnelAuth = _s(bean, 'dnsTunnelAuth');
      _dnsTunnelMethod =
          bean['dnsTunnelMethod'] is num && (bean['dnsTunnelMethod'] as num) > 0 ? '${(bean['dnsTunnelMethod'] as num).toInt()}' : '';
      _dnsTunnelFixedUpstream = bean['dnsTunnelFixedUpstream'] == true;
      _dnsTunnelSpare = _s(bean, 'dnsTunnelSpare');
      _knockSequence = _s(bean, 'knockSequence');
      _udpPrelude = bean['udpPrelude'] != null && bean['udpPrelude'] != 0 ? '${bean['udpPrelude']}' : '';
      _udpPreludeSni = _s(bean, 'udpPreludeSni');
      _udpPreludeTtl = bean['udpPreludeTtl'] != null && bean['udpPreludeTtl'] != 0 ? '${bean['udpPreludeTtl']}' : '';
      _udpReorderInitial = bean['udpReorderInitial'] == true;
      _yggPeer = _s(bean, 'yggPeer');
      return true;
    } catch (_) {
      return false;
    }
  }

  String _wireType() => _type == 'vless' ? 'vmess' : _type;

  void _setStr(Map<String, Object?> bean, String key, String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      bean[key] = trimmed;
    } else {
      bean.remove(key);
    }
  }

  void _setInt(Map<String, Object?> bean, String key, String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null && parsed > 0) {
      bean[key] = parsed;
    } else {
      bean.remove(key);
    }
  }

  String _composeBeanJson() {
    if (_rawMode) return _rawJson.trim();
    final portText = _port.trim();
    final port = int.tryParse(portText) ?? 0;
    final bean = <String, Object?>{
      ..._baseBean,
      'name': _name.trim(),
      'serverAddress': _server.trim(),
    };

    if (_type == 'hysteria') {
      bean.remove('serverPort');
      bean['serverPorts'] = portText.isEmpty ? '443' : portText;
      bean['protocolVersion'] ??= 2;
      bean['authPayload'] = _password;
      _setStr(bean, 'obfuscation', _obfs);
      _setStr(bean, 'sni', _sni);
      _setInt(bean, 'uploadMbps', _upMbps);
      _setInt(bean, 'downloadMbps', _downMbps);
      _setInt(bean, 'hopInterval', _hopInterval);
      if (_allowInsecure) {
        bean['allowInsecure'] = true;
      } else {
        bean.remove('allowInsecure');
      }
    } else {
      bean['serverPort'] = port;
      switch (_type) {
        case 'socks' || 'http':
          bean['username'] = _username;
          bean['password'] = _password;
        case 'vless':
          bean['alterId'] = -1;
          bean['uuid'] = _password;
          bean['security'] = _security.trim().isEmpty ? 'tls' : _security.trim();
          bean['type'] = _transport.trim().isEmpty ? 'tcp' : _transport.trim();
          _setStr(bean, 'sni', _sni);
          _setStr(bean, 'host', _host);
          _setStr(bean, 'path', _path);
          _setStr(bean, 'encryption', _flow);
          _setStr(bean, 'utlsFingerprint', _utlsFingerprint);
          _setStr(bean, 'realityPubKey', _realityPubKey);
          _setStr(bean, 'realityShortId', _realityShortId);
          _setStr(bean, 'vlessEncryption', _vlessEncryption);
          if (_transport == 'xhttp') _setStr(bean, 'xhttpMode', _xhttpMode);
          _setStr(bean, 'alpn', _alpn);
          if (_allowInsecure) {
            bean['allowInsecure'] = true;
          } else {
            bean.remove('allowInsecure');
          }
        case 'vmess':
          if (bean['alterId'] == -1) bean['alterId'] = 0;
          bean['uuid'] = _password;
          _setStr(bean, 'security', _security == 'tls' ? 'auto' : _security);
          _setStr(bean, 'type', _transport);
          _setStr(bean, 'sni', _sni);
          _setStr(bean, 'host', _host);
          _setStr(bean, 'path', _path);
          if (_allowInsecure) {
            bean['allowInsecure'] = true;
          } else {
            bean.remove('allowInsecure');
          }
        case 'trojan' || 'trojan-go':
          bean['password'] = _password;
          _setStr(bean, 'sni', _sni);
          if (_type == 'trojan') {
            _setStr(bean, 'type', _transport);
            _setStr(bean, 'host', _host);
            _setStr(bean, 'path', _path);
          }
          if (_allowInsecure) {
            bean['allowInsecure'] = true;
          } else {
            bean.remove('allowInsecure');
          }
        case 'ss':
          _setStr(bean, 'method', _username.isEmpty ? '2022-blake3-aes-128-gcm' : _username);
          bean['password'] = _password;
        case 'tuic':
          bean['uuid'] = _username;
          bean['token'] = _password;
          _setStr(bean, 'congestionController', _congestionControl);
          _setStr(bean, 'udpRelayMode', _udpRelayMode);
          _setStr(bean, 'sni', _sni);
          if (_allowInsecure) {
            bean['allowInsecure'] = true;
          } else {
            bean.remove('allowInsecure');
          }
        case 'anytls':
          bean['password'] = _password;
          _setStr(bean, 'sni', _sni);
          _setStr(bean, 'alpn', _alpn);
          _setStr(bean, 'utlsFingerprint', _utlsFingerprint);
          if (_allowInsecure) {
            bean['allowInsecure'] = true;
          } else {
            bean.remove('allowInsecure');
          }
        case 'naive':
          bean['proto'] = _naiveProto == 'quic' ? 'quic' : 'https';
          bean['username'] = _username;
          bean['password'] = _password;
          _setStr(bean, 'sni', _sni);
          _setStr(bean, 'extraHeaders', _naiveExtraHeaders);
          _setInt(bean, 'insecureConcurrency', _naiveInsecureConcurrency);
          _setStr(bean, 'certificates', _naiveCertificates);
          if (_nikoUdp) {
            bean['nikoUdp'] = true;
            bean['sUoT'] = true;
          } else {
            bean.remove('nikoUdp');
            if (_sUoT) {
              bean['sUoT'] = true;
            } else {
              bean.remove('sUoT');
            }
          }
          if (_nikoAck) {
            bean['nikoAck'] = true;
          } else {
            bean.remove('nikoAck');
          }
          if (_nikoIcmp) {
            bean['nikoIcmp'] = true;
          } else {
            bean.remove('nikoIcmp');
          }
        case 'chain':
          bean.remove('serverAddress');
          bean.remove('serverPort');
          bean['proxies'] = _chainProxies;
        case 'wg':
          bean['privateKey'] = _password;
          _setStr(bean, 'peerPublicKey', _username);
          _setStr(bean, 'peerPreSharedKey', _preSharedKey);
          _setStr(bean, 'localAddress', _localAddress);
          _setInt(bean, 'mtu', _mtu);
          _setStr(bean, 'amneziaWG', _amneziaWg);
        case 'mieru':
          bean['username'] = _username;
          bean['password'] = _password;
          bean['protocol'] = _mieruProto.toUpperCase() == 'UDP' ? 'UDP' : 'TCP';
        case 'ssh':
          bean['username'] = _username;
          bean['password'] = _password;
        default:
          // Preserve raw bean for types without structured fields (chain, config, shadowtls).
          break;
      }
    }

    // AbstractBean fine-tuning fields (D-PROFILE-03)
    _setStr(bean, 'certPins', _certPins);
    _setInt(bean, 'tlsFragment', _tlsFragment);
    _setStr(bean, 'dnsTunnel', _dnsTunnel);
    _setStr(bean, 'dnsTunnelDomain', _dnsTunnelDomain);
    _setStr(bean, 'dnsTunnelResolver', _dnsTunnelResolver);
    _setStr(bean, 'dnsTunnelKey', _dnsTunnelKey);
    _setStr(bean, 'dnsTunnelSeal', _dnsTunnelSeal);
    _setStr(bean, 'dnsTunnelTls', _dnsTunnelTls);
    _setStr(bean, 'dnsTunnelAuth', _dnsTunnelAuth);
    _setInt(bean, 'dnsTunnelMethod', _dnsTunnelMethod);
    if (_dnsTunnelFixedUpstream) {
      bean['dnsTunnelFixedUpstream'] = true;
    } else {
      bean.remove('dnsTunnelFixedUpstream');
    }
    _setStr(bean, 'dnsTunnelSpare', _dnsTunnelSpare);
    _setStr(bean, 'knockSequence', _knockSequence);
    _setInt(bean, 'udpPrelude', _udpPrelude);
    _setStr(bean, 'udpPreludeSni', _udpPreludeSni);
    _setInt(bean, 'udpPreludeTtl', _udpPreludeTtl);
    if (_udpReorderInitial) {
      bean['udpReorderInitial'] = true;
    } else {
      bean.remove('udpReorderInitial');
    }
    _setStr(bean, 'yggPeer', _yggPeer);

    return const JsonEncoder.withIndent('  ').convert(bean);
  }

  void _toggleRawMode() {
    setState(() {
      _error = null;
      _checkResult = null;
      if (!_rawMode) {
        _rawJson = _composeBeanJson();
        _rawMode = true;
      } else {
        if (_rawJson.trim().isEmpty || _loadFromJson(_rawJson)) {
          _rawMode = false;
        } else {
          _error = 'Invalid JSON';
        }
      }
    });
  }

  Future<void> _check() async {
    final onCheck = widget.onCheck;
    if (onCheck == null) return;
    setState(() {
      _checking = true;
      _error = null;
      _checkResult = null;
    });
    final res = await onCheck(type: _wireType(), beanJson: _composeBeanJson());
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checkResult = res;
      if (!res.ok && res.error.isNotEmpty) {
        _error = res.error;
      }
    });
  }

  Future<void> _save() async {
    if (!_rawMode && _type == 'chain' && _chainProxies.isEmpty) {
      setState(() => _error = 'Chain requires at least one hop');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await widget.onSave(
      id: widget.profileId,
      groupId: widget.groupId,
      type: _wireType(),
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
    final showUser = const {'socks', 'http', 'ss', 'tuic', 'naive', 'wg', 'mieru', 'ssh'}.contains(_type);
    final showSni = const {'vless', 'vmess', 'trojan', 'trojan-go', 'hysteria', 'naive', 'tuic', 'anytls'}.contains(_type);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
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
                          : NikoTonalButton(
                              label: label,
                              onPressed: () => setState(() {
                                _type = code;
                                // Clear stale base bean fields from previous protocol type (M6).
                                _baseBean = {};
                                if (code == 'vmess' && _security == 'tls') {
                                  _security = 'auto';
                                } else if (code == 'vless' && _security == 'auto') {
                                  _security = 'tls';
                                }
                              }),
                            ),
                  ],
                ),
                const SizedBox(height: NikoSpace.s4),
              ],
              Row(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleRawMode,
                    child: NikoSwitch(on: _rawMode),
                  ),
                  const SizedBox(width: NikoSpace.s3),
                  NikoGhostButton(label: strings.profileRawJson, onPressed: _toggleRawMode),
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
                if (_type != 'chain') ...[
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: strings.profileServer,
                    value: _server,
                    mono: true,
                    onChanged: (v) => setState(() => _server = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: _type == 'hysteria' ? '${strings.profilePort} (443 / 443,5000-6000)' : strings.profilePort,
                    value: _port,
                    input: _type == 'hysteria' ? FieldInput.text : FieldInput.port,
                    mono: true,
                    onChanged: (v) => setState(() => _port = v),
                  ),
                ] else ...[
                  const SizedBox(height: NikoSpace.s4),
                  Text(strings.profileChainHops, style: NikoType.bodySm.style(colors.ink2)),
                  const SizedBox(height: NikoSpace.s2),
                  for (var i = 0; i < _chainProxies.length; i++) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            () {
                              final hopId = _chainProxies[i];
                              final found = widget.availableProfiles.where((p) => p.id == hopId).firstOrNull;
                              return '${i + 1}. ${found?.name ?? 'Profile #$hopId'}';
                            }(),
                            style: NikoType.body.style(colors.ink),
                          ),
                        ),
                        NikoGhostButton(
                          label: '×',
                          onPressed: () => setState(() => _chainProxies.removeAt(i)),
                        ),
                      ],
                    ),
                    const SizedBox(height: NikoSpace.s1),
                  ],
                  if (widget.availableProfiles.isNotEmpty) ...[
                    const SizedBox(height: NikoSpace.s2),
                    Wrap(
                      spacing: NikoSpace.s2,
                      runSpacing: NikoSpace.s2,
                      children: [
                        for (final p in widget.availableProfiles)
                          if (p.id != widget.profileId && p.type != 'chain')
                            NikoTonalButton(
                              label: '+ ${p.name}',
                              onPressed: () => setState(() => _chainProxies.add(p.id)),
                            ),
                      ],
                    ),
                  ],
                ],
                if (showUser) ...[
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: switch (_type) {
                      'ss' => 'Method (2022-blake3-aes-128-gcm)',
                      'tuic' => 'UUID',
                      'wg' => 'Peer Public Key',
                      _ => strings.profileUsername,
                    },
                    value: _username,
                    mono: true,
                    onChanged: (v) => setState(() => _username = v),
                  ),
                ],
                if (_type != 'chain') ...[
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: switch (_type) {
                      'vless' || 'vmess' => 'UUID',
                      'wg' => 'Private Key',
                      'tuic' => 'Token',
                      _ => strings.profilePassword,
                    },
                    value: _password,
                    input: FieldInput.secret,
                    mono: true,
                    onChanged: (v) => setState(() => _password = v),
                  ),
                ],
                if (showSni) ...[
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: strings.profileSni,
                    value: _sni,
                    mono: true,
                    onChanged: (v) => setState(() => _sni = v),
                  ),
                ],

                // Protocol-specific sections
                if (_type == 'vless') ...[
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Transport (tcp / ws / grpc / xhttp)',
                    value: _transport,
                    mono: true,
                    onChanged: (v) => setState(() => _transport = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Flow (xtls-rprx-vision)',
                    value: _flow,
                    mono: true,
                    onChanged: (v) => setState(() => _flow = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'REALITY Public Key',
                    value: _realityPubKey,
                    mono: true,
                    onChanged: (v) => setState(() => _realityPubKey = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'REALITY Short ID',
                    value: _realityShortId,
                    mono: true,
                    onChanged: (v) => setState(() => _realityShortId = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'VLESS Encryption (ML-KEM / pqv)',
                    value: _vlessEncryption,
                    mono: true,
                    onChanged: (v) => setState(() => _vlessEncryption = v),
                  ),
                  if (_transport == 'ws' || _transport == 'grpc' || _transport == 'xhttp') ...[
                    const SizedBox(height: NikoSpace.s3),
                    NikoField(label: 'Host', value: _host, mono: true, onChanged: (v) => setState(() => _host = v)),
                    const SizedBox(height: NikoSpace.s3),
                    NikoField(label: 'Path', value: _path, mono: true, onChanged: (v) => setState(() => _path = v)),
                  ],
                  if (_transport == 'xhttp') ...[
                    const SizedBox(height: NikoSpace.s3),
                    NikoField(
                      label: 'XHTTP Mode (auto / packet-up / stream-up / stream-one)',
                      value: _xhttpMode,
                      mono: true,
                      onChanged: (v) => setState(() => _xhttpMode = v),
                    ),
                  ],
                ],

                if (_type == 'hysteria') ...[
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Salamander Obfs Password',
                    value: _obfs,
                    input: FieldInput.secret,
                    mono: true,
                    onChanged: (v) => setState(() => _obfs = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Upload Mbps (e.g. 50)',
                    value: _upMbps,
                    mono: true,
                    onChanged: (v) => setState(() => _upMbps = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Download Mbps (e.g. 100)',
                    value: _downMbps,
                    mono: true,
                    onChanged: (v) => setState(() => _downMbps = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Hop Interval (sec)',
                    value: _hopInterval,
                    mono: true,
                    onChanged: (v) => setState(() => _hopInterval = v),
                  ),
                ],

                if (_type == 'naive') ...[
                  const SizedBox(height: NikoSpace.s3),
                  Wrap(
                    spacing: NikoSpace.s2,
                    children: [
                      for (final p in const ['https', 'quic'])
                        _naiveProto == p
                            ? NikoPrimaryButton(label: 'naive+$p', onPressed: () {})
                            : NikoTonalButton(label: 'naive+$p', onPressed: () => setState(() => _naiveProto = p)),
                    ],
                  ),
                  const SizedBox(height: NikoSpace.s2),
                  NikoSwitchRow(
                    title: 'UDP over TCP (sUoT)',
                    on: _sUoT || _nikoUdp,
                    divider: true,
                    onChanged: (v) => setState(() {
                      _sUoT = v;
                      if (!v) _nikoUdp = false;
                    }),
                  ),
                  NikoSwitchRow(
                    title: 'UDP over HTTP/3 (niko-udp)',
                    on: _nikoUdp,
                    divider: true,
                    onChanged: (v) => setState(() {
                      _nikoUdp = v;
                      if (v) _sUoT = true;
                    }),
                  ),
                  NikoSwitchRow(
                    title: 'Honest connect (niko-ack)',
                    on: _nikoAck,
                    divider: true,
                    onChanged: (v) => setState(() => _nikoAck = v),
                  ),
                  NikoSwitchRow(
                    title: 'ICMP through node (niko-icmp)',
                    on: _nikoIcmp,
                    divider: false,
                    onChanged: (v) => setState(() => _nikoIcmp = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Extra Headers (Key: Value)',
                    value: _naiveExtraHeaders,
                    input: FieldInput.lines,
                    mono: true,
                    onChanged: (v) => setState(() => _naiveExtraHeaders = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Insecure Concurrency',
                    value: _naiveInsecureConcurrency,
                    mono: true,
                    onChanged: (v) => setState(() => _naiveInsecureConcurrency = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Custom Server Certificate (PEM)',
                    value: _naiveCertificates,
                    input: FieldInput.lines,
                    mono: true,
                    onChanged: (v) => setState(() => _naiveCertificates = v),
                  ),
                ],

                if (_type == 'wg') ...[
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Local Address (CIDR)',
                    value: _localAddress,
                    mono: true,
                    onChanged: (v) => setState(() => _localAddress = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Pre-Shared Key',
                    value: _preSharedKey,
                    input: FieldInput.secret,
                    mono: true,
                    onChanged: (v) => setState(() => _preSharedKey = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(label: 'MTU', value: _mtu, mono: true, onChanged: (v) => setState(() => _mtu = v)),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'AmneziaWG (Jc/Jmin/Jmax/S1-S4/H1-H4/I1-I5)',
                    value: _amneziaWg,
                    input: FieldInput.lines,
                    mono: true,
                    onChanged: (v) => setState(() => _amneziaWg = v),
                  ),
                ],

                if (_type == 'mieru') ...[
                  const SizedBox(height: NikoSpace.s3),
                  Wrap(
                    spacing: NikoSpace.s2,
                    children: [
                      for (final p in const ['TCP', 'UDP'])
                        _mieruProto.toUpperCase() == p
                            ? NikoPrimaryButton(label: p, onPressed: () {})
                            : NikoTonalButton(label: p, onPressed: () => setState(() => _mieruProto = p)),
                    ],
                  ),
                ],

                // Collapsible Fine-Tuning (D-PROFILE-03)
                const SizedBox(height: NikoSpace.s4),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: NikoGhostButton(
                    label: strings.save == 'Сохранить'
                        ? (_showTuning ? 'Скрыть тонкую настройку' : 'Тонкая настройка (TLS / DNS-туннель / Knock)')
                        : (_showTuning ? 'Hide fine-tuning' : 'Fine-tuning (TLS / DNS tunnel / Knock)'),
                    onPressed: () => setState(() => _showTuning = !_showTuning),
                  ),
                ),
                if (_showTuning) ...[
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Certificate Pins (SHA-256)',
                    value: _certPins,
                    mono: true,
                    onChanged: (v) => setState(() => _certPins = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'TLS Fragment (0=off, 1=on)',
                    value: _tlsFragment,
                    mono: true,
                    onChanged: (v) => setState(() => _tlsFragment = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'DNS Tunnel Engine (dnstt / masterdnsvpn / slipstream)',
                    value: _dnsTunnel,
                    mono: true,
                    onChanged: (v) => setState(() => _dnsTunnel = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'DNS Tunnel Domain',
                    value: _dnsTunnelDomain,
                    mono: true,
                    onChanged: (v) => setState(() => _dnsTunnelDomain = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'DNS Tunnel Resolver',
                    value: _dnsTunnelResolver,
                    mono: true,
                    onChanged: (v) => setState(() => _dnsTunnelResolver = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'DNS Tunnel Key',
                    value: _dnsTunnelKey,
                    input: FieldInput.secret,
                    mono: true,
                    onChanged: (v) => setState(() => _dnsTunnelKey = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'DNS Tunnel Seal',
                    value: _dnsTunnelSeal,
                    mono: true,
                    onChanged: (v) => setState(() => _dnsTunnelSeal = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'DNS Tunnel TLS (alpn;sni)',
                    value: _dnsTunnelTls,
                    mono: true,
                    onChanged: (v) => setState(() => _dnsTunnelTls = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'DNS Tunnel Auth (v2;nodeId;svcId)',
                    value: _dnsTunnelAuth,
                    mono: true,
                    onChanged: (v) => setState(() => _dnsTunnelAuth = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'DNS Tunnel Method (1=dot, 2=doh)',
                    value: _dnsTunnelMethod,
                    input: FieldInput.port,
                    mono: true,
                    onChanged: (v) => setState(() => _dnsTunnelMethod = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  Row(
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _dnsTunnelFixedUpstream = !_dnsTunnelFixedUpstream),
                        child: NikoSwitch(on: _dnsTunnelFixedUpstream),
                      ),
                      const SizedBox(width: NikoSpace.s3),
                      Expanded(
                        child: Text('DNS Tunnel Fixed Upstream', style: NikoType.body.style(colors.ink)),
                      ),
                    ],
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'DNS Tunnel Spare Zones',
                    value: _dnsTunnelSpare,
                    mono: true,
                    onChanged: (v) => setState(() => _dnsTunnelSpare = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Port Knocking Sequence',
                    value: _knockSequence,
                    mono: true,
                    onChanged: (v) => setState(() => _knockSequence = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'UDP Prelude Count',
                    value: _udpPrelude,
                    mono: true,
                    onChanged: (v) => setState(() => _udpPrelude = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'UDP Prelude TTL',
                    value: _udpPreludeTtl,
                    mono: true,
                    onChanged: (v) => setState(() => _udpPreludeTtl = v),
                  ),
                  const SizedBox(height: NikoSpace.s3),
                  NikoField(
                    label: 'Yggdrasil Peer URI',
                    value: _yggPeer,
                    mono: true,
                    onChanged: (v) => setState(() => _yggPeer = v),
                  ),
                ],
              ],
              if (_checkResult case final check? when check.ok) ...[
                const SizedBox(height: NikoSpace.s4),
                NikoBanner(
                  icon: NikoIcons.search,
                  title: 'OK${check.kind.isNotEmpty ? ' · ${check.kind} (${check.transport})' : ''}',
                  text: check.warnings.join('\n'),
                ),
              ],
              if (_error != null && _error!.isNotEmpty) ...[
                const SizedBox(height: NikoSpace.s4),
                NikoBanner(icon: NikoIcons.alert, title: strings.saveFailed, text: _error!, danger: true),
              ],
              const SizedBox(height: NikoSpace.s6),
              Wrap(
                spacing: NikoSpace.s3,
                runSpacing: NikoSpace.s2,
                children: [
                  NikoPrimaryButton(label: strings.save, onPressed: _saving ? null : _save),
                  if (widget.onCheck != null)
                    NikoTonalButton(label: _checking ? '...' : strings.checkButton, onPressed: _checking ? null : _check),
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
