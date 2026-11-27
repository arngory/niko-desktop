/// Extracts and normalizes desktop URL-scheme deep links passed as CLI arguments or forwarded
/// to an already-running instance (D-ADD-11).
///
/// Supported forms:
/// - `--url <uri>` (preferred from OS protocol registrations to avoid CLI flag injection)
/// - `niko://import?url=<encoded>` / `niko://add?url=<encoded>` -> decodes raw `url=`/`link=`/`config=`
///   component and recursively validates the inner URI (rejecting nested `niko://` or unsupported schemes)
/// - `sn://...`, `clash://...`, `vless://...`, `vmess://...`, `trojan://...`, `ss://...`,
///   `hysteria2://...`, `hy2://...`, `tuic://...`, `naive+https://...`, `rcinv1://...`, `rcinv2://...`, `rcinv3://...`
library;

const supportedUrlSchemes = <String>{
  'niko',
  'sn',
  'clash',
  'vless',
  'vmess',
  'trojan',
  'ss',
  'hysteria2',
  'hy2',
  'tuic',
  'naive+https',
  'rcinv1',
  'rcinv2',
  'rcinv3',
};

const _innerImportSchemes = <String>{
  'http',
  'https',
  'sn',
  'clash',
  'vless',
  'vmess',
  'trojan',
  'ss',
  'hysteria2',
  'hy2',
  'tuic',
  'naive+https',
  'rcinv1',
  'rcinv2',
  'rcinv3',
};

/// Returns the normalized import link from command-line [arguments], or null if none is present.
String? extractDeepLink(List<String> arguments) {
  for (var i = 0; i < arguments.length; i++) {
    final arg = arguments[i].trim();
    if (arg == '--url' && i + 1 < arguments.length) {
      return normalizeDeepLink(arguments[i + 1]);
    }
    if (arg.startsWith('--url=')) {
      return normalizeDeepLink(arg.substring('--url='.length));
    }
  }
  for (final raw in arguments) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.startsWith('-')) continue;
    final parsed = normalizeDeepLink(trimmed);
    if (parsed != null) return parsed;
  }
  return null;
}

/// Normalizes a single deep-link URI string into text ready for [AddScreen], or null if unsupported.
String? normalizeDeepLink(String raw) => _normalize(raw, allowWrapper: true);

String? _normalize(String raw, {required bool allowWrapper}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.length > 32 * 1024) return null;
  final colon = trimmed.indexOf('://');
  if (colon <= 0) return null;
  final scheme = trimmed.substring(0, colon).toLowerCase();
  final allowed = allowWrapper ? supportedUrlSchemes : _innerImportSchemes;
  if (!allowed.contains(scheme)) return null;

  if (scheme == 'niko') {
    if (!allowWrapper) return null;
    final rest = trimmed.substring('niko://'.length);
    final qIdx = rest.indexOf('?');
    final host = (qIdx >= 0 ? rest.substring(0, qIdx) : rest).split('/').first.toLowerCase();
    if (qIdx >= 0 && (host == 'import' || host == 'add' || host == 'install-config')) {
      final rawQuery = rest.substring(qIdx + 1);
      final innerRaw = _extractRawParam(rawQuery, const ['url', 'link', 'config']);
      if (innerRaw != null && innerRaw.isNotEmpty) {
        String decoded;
        try {
          decoded = Uri.decodeComponent(innerRaw).trim();
        } catch (_) {
          decoded = innerRaw.trim();
        }
        return _normalize(decoded, allowWrapper: false);
      }
      return null;
    }
  }
  return trimmed;
}

/// Extracts the raw value of the first matching parameter (`url=`, `link=`, `config=`) without
/// mangling `+`, `&`, or `#` inside unencoded proxy/subscription URIs.
String? _extractRawParam(String rawQuery, List<String> keys) {
  for (final key in keys) {
    final prefix = '$key=';
    if (rawQuery.startsWith(prefix)) {
      return rawQuery.substring(prefix.length);
    }
    final idx = rawQuery.indexOf('&$prefix');
    if (idx >= 0) {
      return rawQuery.substring(idx + 1 + prefix.length);
    }
  }
  return null;
}
