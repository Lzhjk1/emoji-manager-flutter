import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/close_button_behavior.dart';

class WindowControlService {
  WindowControlService._();

  static const MethodChannel _channel = MethodChannel(
    'emoji_manager/window_control',
  );

  /// MOD_* constants matching the Win32 definitions.
  static const int hotkeyModifierAlt = 0x1;
  static const int hotkeyModifierControl = 0x2;
  static const int hotkeyModifierShift = 0x4;
  static const int hotkeyModifierWin = 0x8;

  static bool get isSupported => !kIsWeb && Platform.isWindows;

  static Future<void> applySettings({
    required CloseButtonBehavior closeBehavior,
    required bool alwaysOnTop,
  }) async {
    if (!isSupported) {
      return;
    }

    await _channel.invokeMethod<void>(
      'applyWindowSettings',
      <String, Object>{
        'closeBehavior': closeBehavior.storageValue,
        'alwaysOnTop': alwaysOnTop,
      },
    );
  }

  /// Returns the executable name (lowercase, e.g. `qq.exe`) of the most
  /// recent foreground window that is not this app, or null when unknown.
  static Future<String?> getPreviousForegroundProcessName() async {
    if (!isSupported) {
      return null;
    }

    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getPreviousForegroundApp');
      final name = result?['processName'];
      if (name is String && name.isNotEmpty) {
        return name;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> setHotkey({
    required bool enabled,
    required int modifiers,
    required int keyCode,
  }) async {
    if (!isSupported) {
      return false;
    }

    try {
      final registered = await _channel.invokeMethod<bool>(
        'setHotkeyEnabled',
        <String, Object>{
          'enabled': enabled,
          'modifiers': modifiers,
          'keyCode': keyCode,
        },
      );
      return registered ?? false;
    } catch (_) {
      return false;
    }
  }
}
