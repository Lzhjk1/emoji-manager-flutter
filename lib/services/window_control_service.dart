import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/close_button_behavior.dart';

class WindowControlService {
  WindowControlService._();

  static const MethodChannel _channel = MethodChannel(
    'emoji_manager/window_control',
  );

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
}
