import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlatformEmojiClipboardService {
  PlatformEmojiClipboardService._();

  static const MethodChannel _channel = MethodChannel(
    'emoji_manager/platform_clipboard',
  );

  static Future<bool> copyFile(String filePath) async {
    if (!File(filePath).existsSync()) {
      return false;
    }

    if (kIsWeb) {
      await Clipboard.setData(ClipboardData(text: filePath));
      return true;
    }

    if (Platform.isWindows) {
      return _copyFileOnWindows(filePath);
    }

    await Clipboard.setData(ClipboardData(text: filePath));
    return true;
  }

  static Future<bool> _copyFileOnWindows(String filePath) async {
    try {
      final copied = await _channel.invokeMethod<bool>(
        'copyFileToClipboard',
        <String, Object>{
          'path': filePath,
        },
      );
      return copied ?? false;
    } catch (_) {
      return false;
    }
  }
}
