import 'dart:io';

/// Where the window keeps its own settings: a folder of the user's, as each system names it. Null: none can be
/// told (no home), and the settings live as long as the window.
File? settingsFile([Map<String, String>? environment, String? os]) {
  final env = environment ?? Platform.environment;
  final system = os ?? Platform.operatingSystem;
  String? present(String? value) => value == null || value.isEmpty ? null : value;
  String? absolute(String? value) => value != null && value.startsWith('/') ? value : null;
  switch (system) {
    case 'windows':
      final base = present(env['APPDATA']);
      return base == null ? null : File('$base\\Niko\\window.json');
    case 'macos':
      final home = present(env['HOME']);
      return home == null ? null : File('$home/Library/Application Support/Niko/window.json');
    default:
      final home = present(env['HOME']);
      final base = absolute(env['XDG_CONFIG_HOME']) ?? (home == null ? null : '$home/.config');
      return base == null ? null : File('$base/niko/window.json');
  }
}

/// Reads [key] from the contents of an `xdg-user-dirs` `user-dirs.dirs` file.
///
/// Only `$HOME/` at the start of a quoted value is expanded, and only an absolute path is returned. Malformed lines
/// are skipped (as glib does). A value equal to `$HOME` marks the directory as disabled by the xdg-user-dirs
/// specification and returns null.
String? xdgUserDir(String contents, String home, String key) {
  final prefix = '$key=';
  String? result;
  for (final rawLine in contents.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#') || !line.startsWith(prefix)) continue;
    final value = line.substring(prefix.length).trim();
    if (value.length < 2 || !value.startsWith('"') || !value.endsWith('"')) continue;
    final inner = value.substring(1, value.length - 1);
    if (inner == r'$HOME' || inner == r'$HOME/') {
      result = null;
      continue;
    }
    String? candidate;
    if (inner.startsWith(r'$HOME/')) {
      if (home.startsWith('/')) {
        final base = home.length > 1 && home.endsWith('/') ? home.substring(0, home.length - 1) : home;
        candidate = base == '/' ? inner.substring(5) : '$base${inner.substring(5)}';
      }
    } else if (inner.startsWith('/')) {
      candidate = inner;
    }
    if (candidate != null && !candidate.contains('\x00')) result = candidate;
  }
  return result;
}

/// Where a file the user asked for is saved: their Downloads folder where there is one, else their home.
Directory? saveDirectory([Map<String, String>? environment, String? os]) {
  final env = environment ?? Platform.environment;
  final system = os ?? Platform.operatingSystem;
  final separator = system == 'windows' ? '\\' : '/';
  final home = system == 'windows' ? env['USERPROFILE'] : env['HOME'];
  String? absolute(String? value) => value != null && value.startsWith('/') ? value : null;
  final named = system == 'windows' || system == 'macos' ? null : absolute(env['XDG_DOWNLOAD_DIR']);
  String? configured;
  if (system != 'windows' && system != 'macos') {
    final configBase =
        absolute(env['XDG_CONFIG_HOME']) ?? (home != null && home.isNotEmpty ? '$home/.config' : null);
    if (configBase != null) {
      final dirsFile = File('$configBase/user-dirs.dirs');
      try {
        if (dirsFile.existsSync()) {
          configured = xdgUserDir(dirsFile.readAsStringSync(), home ?? '', 'XDG_DOWNLOAD_DIR');
        }
      } catch (_) {
        // unreadable user-dirs.dirs falls back to ~/Downloads and $HOME
      }
    }
  }
  for (final path in [named, configured, if (home != null && home.isNotEmpty) '$home${separator}Downloads', home]) {
    if (path != null && path.isNotEmpty && Directory(path).existsSync()) return Directory(path);
  }
  return null;
}

/// [name] as a file name and nothing else, never a path: the daemon's names and the window's alike.
String safeFileName(String name) {
  final last = name.split(RegExp(r'[\\/]')).last;
  final clean = last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').replaceAll(RegExp(r'^\.+'), '');
  return clean.isEmpty ? 'niko' : clean;
}

/// Writes [data] as [name] in [directory] and never over a file already there: `name (2).ext` and on.
Future<File> saveNew(Directory directory, String name, List<int> data) async {
  final safe = safeFileName(name);
  final dot = safe.indexOf('.', 1);
  final stem = dot < 0 ? safe : safe.substring(0, dot);
  final extension = dot < 0 ? '' : safe.substring(dot);
  for (var n = 1; n < 1000; n++) {
    final file = File('${directory.path}${Platform.pathSeparator}${n == 1 ? stem : '$stem ($n)'}$extension');
    try {
      // made only where nothing is: two saves at once never share a file
      await file.create(exclusive: true);
    } on FileSystemException {
      continue;
    }
    await file.writeAsBytes(data, flush: true);
    return file;
  }
  throw FileSystemException('no free name for $safe', directory.path);
}
