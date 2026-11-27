import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Platform integration bridge over the `niko/window` MethodChannel:
/// - System tray icon, status, and compact context menu (`D-TRAY`)
/// - Native desktop notifications (`D-TRAY`)
/// - Native file and save-folder pickers (`D-ADD-09`, Logs/Reports)
/// - Window show/hide for minimize-to-tray
class DesktopIntegration {
  DesktopIntegration({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('niko/window');

  final MethodChannel _channel;
  void Function(String action)? _trayHandler;
  void Function(String url)? _deepLinkHandler;

  void _syncHandler() {
    if (_trayHandler == null && _deepLinkHandler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'trayAction' && call.arguments is String) {
        _trayHandler?.call(call.arguments as String);
      } else if (call.method == 'deepLink' && call.arguments is String) {
        _deepLinkHandler?.call(call.arguments as String);
      }
      return null;
    });
  }

  void setTrayActionHandler(void Function(String action)? handler) {
    _trayHandler = handler;
    _syncHandler();
  }

  void setDeepLinkHandler(void Function(String url)? handler) {
    _deepLinkHandler = handler;
    _syncHandler();
  }

  Future<void> updateTray({
    required bool connected,
    required String statusLabel,
    required String profileName,
    required String toggleLabel,
    required String openLabel,
    required String quitLabel,
  }) async {
    try {
      await _channel.invokeMethod<void>('updateTray', {
        'connected': connected,
        'status': statusLabel,
        'profile': profileName,
        'toggleLabel': toggleLabel,
        'openLabel': openLabel,
        'quitLabel': quitLabel,
      });
    } catch (_) {
      // Headless environments or platforms without a tray host ignore gracefully.
    }
  }

  Future<void> setCloseToTray(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setCloseToTray', enabled);
    } catch (_) {}
  }

  Future<void> showWindow() async {
    try {
      await _channel.invokeMethod<void>('showWindow');
    } catch (_) {}
  }

  Future<void> hideWindow() async {
    try {
      await _channel.invokeMethod<void>('hideWindow');
    } catch (_) {}
  }

  Future<void> closeWindow() async {
    try {
      await _channel.invokeMethod<void>('closeWindow');
    } catch (_) {}
  }

  Future<void> notify({required String title, required String body}) async {
    try {
      final handled = await _channel.invokeMethod<bool>('notify', {'title': title, 'body': body});
      if (handled == true) return;
    } catch (_) {
      // Fall through to Linux notify-send fallback when running outside native runner.
    }
    if (Platform.isLinux && !Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        await Process.start('notify-send', ['--app-name=Niko', title, body], mode: ProcessStartMode.detached);
      } catch (_) {}
    }
  }

  /// Opens a native file dialog and returns the chosen path, or null if cancelled/unavailable.
  Future<String?> pickFile({String title = 'Open file', List<String> extensions = const []}) async {
    try {
      final path = await _channel.invokeMethod<String>('pickFile', {
        'title': title,
        'extensions': extensions,
      });
      return (path != null && path.isNotEmpty) ? path : null;
    } catch (_) {
      return null;
    }
  }

  /// Opens a native directory picker and returns the chosen folder path, or null if cancelled.
  Future<String?> pickDirectory({String title = 'Choose folder'}) async {
    try {
      final path = await _channel.invokeMethod<String>('pickDirectory', {'title': title});
      return (path != null && path.isNotEmpty) ? path : null;
    } catch (_) {
      return null;
    }
  }
}
