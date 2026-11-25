import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../daemon/daemon.dart';
import 'connection_controller.dart';
import 'window_settings.dart';

/// A parsed destination for route checking: host, port 1..65535, and how it is shown in the UI.
class ParsedRouteTarget {
  const ParsedRouteTarget({required this.host, required this.port, required this.ipv6});

  final String host;
  final int port;
  final bool ipv6;

  /// `host` for port 443, otherwise `host:port` (or `[host]:port` for IPv6).
  String get display {
    if (port == 443) return host;
    return ipv6 ? '[$host]:$port' : '$host:$port';
  }
}

/// Parses a user-entered target for route check (D-CHECK-02, -03):
/// trims whitespace, strips URL scheme/path (`http` defaults to 80, else 443), and supports `host:port`, `[v6]:port`,
/// and bare IPv6 addresses. Returns null if empty or invalid.
ParsedRouteTarget? parseRouteTarget(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return null;
  // reject whitespace and control characters
  for (final code in raw.codeUnits) {
    if (code <= 0x20 || code == 0x7f) return null;
  }

  int? parsePort(String text) {
    if (text.isEmpty || text.length > 5) return null;
    for (final code in text.codeUnits) {
      if (code < 0x30 || code > 0x39) return null;
    }
    final port = int.tryParse(text);
    if (port == null || port < 1 || port > 65535) return null;
    return port;
  }

  bool validHost(String host) {
    if (host.isEmpty) return false;
    if (host.contains(RegExp(r'[\[\]/\\?#@:]'))) return false;
    return true;
  }

  // URL form: scheme://host[:port][/path]
  final schemeSep = raw.indexOf('://');
  if (schemeSep >= 0) {
    final scheme = raw.substring(0, schemeSep).toLowerCase();
    if (scheme.isEmpty || !RegExp(r'^[a-z][a-z0-9+.-]*$').hasMatch(scheme)) return null;
    var rest = raw.substring(schemeSep + 3);
    final cut = rest.indexOf(RegExp(r'[/?#]'));
    if (cut >= 0) rest = rest.substring(0, cut);
    if (rest.isEmpty || rest.contains('@')) return null;
    final defaultPort = scheme == 'http' ? 80 : 443;
    return _parseHostPort(rest, defaultPort: defaultPort, parsePort: parsePort, validHost: validHost);
  }

  return _parseHostPort(raw, defaultPort: 443, parsePort: parsePort, validHost: validHost);
}

ParsedRouteTarget? _parseHostPort(
  String authority, {
  required int defaultPort,
  required int? Function(String) parsePort,
  required bool Function(String) validHost,
}) {
  if (authority.startsWith('[')) {
    final close = authority.indexOf(']');
    if (close < 0) return null;
    final host = authority.substring(1, close);
    final parsedIp = InternetAddress.tryParse(host);
    if (parsedIp == null || parsedIp.type != InternetAddressType.IPv6) return null;
    final tail = authority.substring(close + 1);
    if (tail.isEmpty) return ParsedRouteTarget(host: host, port: defaultPort, ipv6: true);
    if (!tail.startsWith(':')) return null;
    final port = parsePort(tail.substring(1));
    if (port == null) return null;
    return ParsedRouteTarget(host: host, port: port, ipv6: true);
  }

  final firstColon = authority.indexOf(':');
  if (firstColon < 0) {
    if (!validHost(authority)) return null;
    return ParsedRouteTarget(host: authority, port: defaultPort, ipv6: false);
  }

  // multiple colons without brackets: bare IPv6
  if (authority.indexOf(':', firstColon + 1) >= 0) {
    final parsedIp = InternetAddress.tryParse(authority);
    if (parsedIp == null || parsedIp.type != InternetAddressType.IPv6) return null;
    return ParsedRouteTarget(host: authority, port: defaultPort, ipv6: true);
  }

  final host = authority.substring(0, firstColon);
  final port = parsePort(authority.substring(firstColon + 1));
  if (!validHost(host) || port == null) return null;
  return ParsedRouteTarget(host: host, port: port, ipv6: false);
}

/// State of the «Проверка маршрута» section (D-CHECK-02…07).
class RouteCheckController extends ChangeNotifier {
  RouteCheckController(this._link, this._settings);

  final ConnectionController _link;
  final WindowSettings _settings;

  String target = '';
  String network = 'tcp';
  bool busy = false;
  RouteVerdict? verdict;
  ParsedRouteTarget? checkedTarget;
  String checkedNetwork = 'tcp';
  String error = '';

  int _generation = 0;
  bool _disposed = false;

  List<RecentRouteCheck> get recent => _settings.recentChecks;

  void setTarget(String value) {
    if (target == value) return;
    target = value;
    notifyListeners();
  }

  void setNetwork(String value) {
    if (value != 'tcp' && value != 'udp') return;
    if (network == value) return;
    network = value;
    notifyListeners();
  }

  /// Runs `daemon.routeTest` for the current [target] and [network]. Calls [describeOutcome] on a clean verdict to
  /// build the `(outcome, label)` stored in [WindowSettings.recentChecks].
  Future<void> check({
    required bool vpnMode,
    required (String outcome, String label) Function(RouteVerdict verdict) describeOutcome,
  }) async {
    final daemon = _link.daemon;
    final parsed = parseRouteTarget(target);
    if (daemon == null || parsed == null || busy) return;
    final net = network;
    final gen = ++_generation;
    busy = true;
    error = '';
    notifyListeners();
    try {
      final result = await daemon.routeTest(
        parsed.host,
        parsed.port,
        network: net,
        inbound: vpnMode ? '' : 'mixed-in',
        resolve: vpnMode,
      );
      if (_disposed || gen != _generation) return;
      verdict = result;
      checkedTarget = parsed;
      checkedNetwork = net;
      error = '';
      if (result.error.isEmpty) {
        final (outcome, label) = describeOutcome(result);
        _settings.addRecentCheck(RecentRouteCheck(
          target: parsed.display,
          network: net,
          outcome: outcome,
          label: label,
        ));
        unawaited(_settings.save());
      }
    } catch (e) {
      if (_disposed || gen != _generation) return;
      verdict = null;
      checkedTarget = null;
      error = daemonError(e);
    } finally {
      if (!_disposed && gen == _generation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void clearRecent() {
    _settings.clearRecentChecks();
    unawaited(_settings.save());
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
