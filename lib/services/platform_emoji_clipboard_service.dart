import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

class PlatformEmojiClipboardService {
  PlatformEmojiClipboardService._();

  static const MethodChannel _channel = MethodChannel(
    'emoji_manager/platform_clipboard',
  );

  /// Extensions pasted as files instead of bitmap data: GIF keeps its
  /// animation, JPEG keeps its compression (a bitmap paste would be
  /// re-encoded by the receiver as a much larger PNG).
  static const _pasteAsFileExtensions = {'gif', 'jpg', 'jpeg'};

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

  /// Decodes the image at [filePath] and puts it on the clipboard as a
  /// CF_DIB bitmap (the format chat apps such as QQ use when pasting
  /// screenshots), optionally hiding this window and sending Ctrl+V to the
  /// previous foreground app.
  ///
  /// Formats that must not be re-encoded (animated GIFs would be flattened
  /// to a single frame; JPEG would be converted to an oversized PNG) are
  /// pasted as files instead, preserving the original data.
  ///
  /// Returns true when the image was placed on the clipboard.
  static Future<bool> copyImageAndPaste(String filePath) async {
    if (kIsWeb || !Platform.isWindows) {
      return false;
    }

    final file = File(filePath);
    if (!file.existsSync()) {
      return false;
    }

    if (_pasteAsFileExtensions.contains(
      filePath.toLowerCase().split('.').last,
    )) {
      try {
        final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'copyFileToClipboard',
          <String, Object>{'path': filePath, 'paste': true},
        );
        return result?['clipboard'] == true;
      } catch (_) {
        return false;
      }
    }

    try {
      final decoded = await compute(_decodeRgba, await file.readAsBytes());
      if (decoded == null) {
        return false;
      }

      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'copyImageToClipboard',
        <String, Object>{
          'width': decoded.$1,
          'height': decoded.$2,
          'bytes': decoded.$3,
          'paste': true,
        },
      );
      return result?['clipboard'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Opens Explorer with the file at [filePath] selected. Uses the shell API
  /// (SHOpenFolderAndSelectItems) so paths with spaces or commas work.
  static Future<bool> revealInExplorer(String filePath) async {
    if (kIsWeb || !Platform.isWindows) {
      return false;
    }

    try {
      final revealed = await _channel.invokeMethod<bool>(
        'revealInExplorer',
        <String, Object>{'path': filePath},
      );
      return revealed ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _copyFileOnWindows(String filePath) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'copyFileToClipboard',
        <String, Object>{
          'path': filePath,
        },
      );
      return result?['clipboard'] == true;
    } catch (_) {
      return false;
    }
  }
}

(int, int, Uint8List)? _decodeRgba(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) {
    return null;
  }
  final rgba = image.getBytes(order: img.ChannelOrder.rgba);
  return (image.width, image.height, rgba);
}
