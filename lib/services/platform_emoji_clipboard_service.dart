import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

/// 平台剪贴板服务: 通过 MethodChannel 调用 Windows 原生代码,
/// 完成图片/文件的复制、自动粘贴与资源管理器定位。
class PlatformEmojiClipboardService {
  PlatformEmojiClipboardService._();

  static const MethodChannel _channel = MethodChannel(
    'emoji_manager/platform_clipboard',
  );

  /// 以"文件"形式粘贴而非位图的扩展名:
  /// GIF 保留动画, JPEG 保留压缩 (转位图粘贴会被接收方重新编码成大得多的 PNG)。
  static const _pasteAsFileExtensions = {'gif', 'jpg', 'jpeg'};

  /// 把文件复制到剪贴板; 非 Windows 平台退化为复制路径文本。
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

  /// 复制图片到剪贴板并触发自动粘贴 (唤起流程用)。
  ///
  /// 普通图片解码后以 CF_DIB 位图格式写入剪贴板 (QQ 等聊天软件
  /// 截图粘贴即为此格式), 可选择隐藏本窗口并向之前的前台应用发送 Ctrl+V。
  /// 不应被重新编码的格式 (动图 GIF 会丢帧; JPEG 会被转成超大 PNG)
  /// 改为以文件形式粘贴, 保留原始数据。
  ///
  /// 成功写入剪贴板返回 true。
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
      // 解码放在后台 isolate, RGBA 字节直接交给原生层构造 DIB。
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

  /// 在资源管理器中打开并选中 [filePath] 指向的文件。
  /// 使用 shell API (SHOpenFolderAndSelectItems), 对含空格/逗号的路径可靠。
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

  /// Windows 平台: 调用原生方法把文件写入剪贴板 (CF_HDROP)。
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

/// 在后台 isolate 中解码图片, 返回 (宽, 高, RGBA 字节) 三元组;
/// 解码失败返回 null。
(int, int, Uint8List)? _decodeRgba(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) {
    return null;
  }
  final rgba = image.getBytes(order: img.ChannelOrder.rgba);
  return (image.width, image.height, rgba);
}
