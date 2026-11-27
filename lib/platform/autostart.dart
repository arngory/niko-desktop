import 'dart:io';

typedef AutostartProcessRunner = Future<ProcessResult> Function(String executable, List<String> arguments);

/// Manages launching the Niko desktop window automatically at user login (D-SET-04).
/// - Linux: XDG autostart desktop entry at `$XDG_CONFIG_HOME/autostart/niko.desktop`.
/// - Windows: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value `Niko` (no admin required).
/// - macOS: LaunchAgent plist at `~/Library/LaunchAgents/io.niko.desktop.plist`.
class DesktopAutostart {
  DesktopAutostart({
    String? executablePath,
    Map<String, String>? environment,
    bool? isWindows,
    bool? isLinux,
    bool? isMacOS,
    AutostartProcessRunner? runProcess,
  })  : _environment = environment ?? Platform.environment,
        _isWindows = isWindows ?? Platform.isWindows,
        _isLinux = isLinux ?? Platform.isLinux,
        _isMacOS = isMacOS ?? Platform.isMacOS,
        _executablePath = _resolveExecutable(
          explicit: executablePath,
          env: environment ?? Platform.environment,
          isLinux: isLinux ?? Platform.isLinux,
        ),
        _runProcess = runProcess ?? ((exe, args) => Process.run(exe, args));

  static String _resolveExecutable({
    required String? explicit,
    required Map<String, String> env,
    required bool isLinux,
  }) {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (isLinux) {
      final appImage = env['APPIMAGE']?.trim();
      if (appImage != null && appImage.isNotEmpty) return appImage;
    }
    return Platform.resolvedExecutable;
  }

  final String _executablePath;
  final Map<String, String> _environment;
  final bool _isWindows;
  final bool _isLinux;
  final bool _isMacOS;
  final AutostartProcessRunner _runProcess;

  static const _winRunKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _winValueName = 'Niko';
  static const _macosLaunchAgentLabel = 'io.niko.desktop';

  File? get linuxDesktopFile {
    final configHome = _environment['XDG_CONFIG_HOME']?.trim();
    if (configHome != null && configHome.isNotEmpty) {
      return File('$configHome/autostart/niko.desktop');
    }
    final home = _environment['HOME']?.trim();
    if (home != null && home.isNotEmpty) {
      return File('$home/.config/autostart/niko.desktop');
    }
    return null;
  }

  File? get macosLaunchAgentFile {
    final home = _environment['HOME']?.trim();
    if (home == null || home.isEmpty) return null;
    return File('$home/Library/LaunchAgents/$_macosLaunchAgentLabel.plist');
  }

  Future<bool> isEnabled() async {
    if (_isLinux) {
      final f = linuxDesktopFile;
      if (f == null || !f.existsSync()) return false;
      try {
        final content = await f.readAsString();
        return !content.contains('Hidden=true') && !content.contains('X-GNOME-Autostart-enabled=false');
      } catch (_) {
        return false;
      }
    }
    if (_isMacOS) {
      final f = macosLaunchAgentFile;
      if (f == null || !f.existsSync()) return false;
      try {
        final content = await f.readAsString();
        return !content.contains('<key>Disabled</key>\n\t<true/>') &&
            !content.contains('<key>Disabled</key><true/>');
      } catch (_) {
        return false;
      }
    }
    if (_isWindows) {
      try {
        final res = await _runProcess('reg', ['query', _winRunKey, '/v', _winValueName]);
        return res.exitCode == 0 && (res.stdout as String).contains(_winValueName);
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  Future<void> setEnabled(bool enabled) async {
    if (_isLinux) {
      final f = linuxDesktopFile;
      if (f == null) return;
      if (!enabled) {
        if (f.existsSync()) await f.delete();
        return;
      }
      await f.parent.create(recursive: true);
      final exec = _quoteDesktopExec(_executablePath);
      final entry = [
        '[Desktop Entry]',
        'Type=Application',
        'Name=Niko',
        'Comment=Niko desktop client',
        'Exec=$exec',
        'Terminal=false',
        'X-GNOME-Autostart-enabled=true',
        '',
      ].join('\n');
      await f.writeAsString(entry, flush: true);
      return;
    }
    if (_isMacOS) {
      final f = macosLaunchAgentFile;
      if (f == null) return;
      if (!enabled) {
        if (f.existsSync()) await f.delete();
        return;
      }
      await f.parent.create(recursive: true);
      final escapedExe = _escapeXml(_executablePath);
      final plist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>Label</key>
\t<string>$_macosLaunchAgentLabel</string>
\t<key>ProgramArguments</key>
\t<array>
\t\t<string>$escapedExe</string>
\t</array>
\t<key>RunAtLoad</key>
\t<true/>
</dict>
</plist>
''';
      await f.writeAsString(plist, flush: true);
      return;
    }
    if (_isWindows) {
      if (enabled) {
        final res = await _runProcess(
          'reg',
          ['add', _winRunKey, '/v', _winValueName, '/t', 'REG_SZ', '/d', '"$_executablePath"', '/f'],
        );
        if (res.exitCode != 0) {
          throw StateError('failed to enable Windows autostart: ${res.stderr}');
        }
      } else {
        await _runProcess('reg', ['delete', _winRunKey, '/v', _winValueName, '/f']);
      }
    }
  }

  static String _escapeXml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String _quoteDesktopExec(String path) {
    final escaped = path
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll(r'$', r'\$')
        .replaceAll('`', r'\`');
    return '"$escaped"';
  }
}
