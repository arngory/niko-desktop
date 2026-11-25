import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// What the window remembers between its launches: the view (Простой or Расширенный), the theme and the language.
/// Kept in a file of the user's ([settingsFile]); a file that is not there or does not read gives the defaults, never
/// a failure. Unknown keys in the JSON file are kept intact across saves.
class WindowSettings extends ChangeNotifier {
  WindowSettings._(
    this._file,
    this._advanced, {
    String theme = 'system',
    String language = 'system',
    Map<String, Object?> extra = const {},
  })  : _theme = normalizeTheme(theme),
        _language = normalizeLanguage(language),
        _extra = Map<String, Object?>.of(extra);

  final File? _file;
  final Map<String, Object?> _extra;

  bool _advanced;
  String _theme;
  String _language;

  /// The view Расширенный.
  bool get advanced => _advanced;
  set advanced(bool value) {
    if (_advanced == value) return;
    _advanced = value;
    notifyListeners();
  }

  /// Window theme: `system`, `light` or `dark`.
  String get theme => _theme;
  set theme(String value) {
    final normalized = normalizeTheme(value);
    if (_theme == normalized) return;
    _theme = normalized;
    notifyListeners();
  }

  /// Window language: `system`, `ru` or `en`.
  String get language => _language;
  set language(String value) {
    final normalized = normalizeLanguage(value);
    if (_language == normalized) return;
    _language = normalized;
    notifyListeners();
  }

  static String normalizeTheme(Object? value) => switch (value) {
        'light' || 'dark' || 'system' => value as String,
        _ => 'system',
      };

  static String normalizeLanguage(Object? value) => switch (value) {
        'ru' || 'en' || 'system' => value as String,
        _ => 'system',
      };

  /// Settings that are kept nowhere: tests, and a system with no home.
  factory WindowSettings.memory({
    bool advanced = false,
    String theme = 'system',
    String language = 'system',
  }) =>
      WindowSettings._(null, advanced, theme: theme, language: language);

  static Future<WindowSettings> load(File? file) async {
    if (file == null) return WindowSettings._(null, false);
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is Map) {
        final extra = <String, Object?>{
          for (final entry in json.entries)
            if (entry.key is String) entry.key as String: entry.value,
        };
        return WindowSettings._(
          file,
          extra['view'] == 'advanced',
          theme: normalizeTheme(extra['theme']),
          language: normalizeLanguage(extra['language']),
          extra: extra,
        );
      }
      return WindowSettings._(file, false);
    } catch (_) {
      return WindowSettings._(file, false);
    }
  }

  // the saves one after another: two at once would share the file beside, and one rename take the other's half
  Future<void> _saves = Future.value();

  /// Finishes when all queued saves have completed; writes nothing on its own.
  Future<void> flush() => _saves;

  /// Writes the settings as they are when its turn comes: a file beside, then renamed over the old one, so a crash
  /// midway leaves one of the two. Saves asked for quickly run one after another; the last writes the last choice.
  Future<void> save() => _saves = _saves.then((_) => _write());

  Future<void> _write() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.new');
      final payload = <String, Object?>{
        ..._extra,
        'view': _advanced ? 'advanced' : 'simple',
        'theme': _theme,
        'language': _language,
      };
      await temporary.writeAsString(jsonEncode(payload), flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      // a setting not remembered is no reason to stop the window
    }
  }
}
