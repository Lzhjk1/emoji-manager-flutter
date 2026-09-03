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
  /// 统一以原文件形式 (CF_HDROP) 复制并粘贴: 接收方拿到原始数据,
  /// 保留 GIF 动画与 JPEG/WebP 压缩; 转位图粘贴会被 QQ 等软件
  /// 重新编码成大得多的 PNG。位图复制入口保留在
  /// [copyImageAsBitmapAndPaste], 供日后遇到更适合位图方式的软件时使用。
  ///
  /// 成功写入剪贴板返回 true。
  static Future<bool> copyImageAndPaste(String filePath) async {
    if (kIsWeb || !Platform.isWindows) {
      return false;
    }

    if (!File(filePath).existsSync()) {
      return false;
    }

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

  /// 以位图 (CF_DIB) 形式复制 [filePath] 并触发自动粘贴 (保留入口, 暂未使用)。
  ///
  /// 解码后把 RGBA 字节交给原生层构造 DIB 写入剪贴板 (QQ 等聊天软件
  /// 截图粘贴即为此格式), 可选择隐藏本窗口并向之前的前台应用发送 Ctrl+V。
  /// 注意: 位图方式会丢失 GIF 动画, 且接收方可能重新编码导致文件变大。
  ///
  /// 成功写入剪贴板返回 true。
  static Future<bool> copyImageAsBitmapAndPaste(String filePath) async {
    if (kIsWeb || !Platform.isWindows) {
      return false;
    }

    final file = File(filePath);
    if (!file.existsSync()) {
      return false;
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
