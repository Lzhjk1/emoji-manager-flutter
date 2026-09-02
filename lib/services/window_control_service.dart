import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/close_button_behavior.dart';

/// 窗口控制服务: 通过 MethodChannel 调用 Windows 原生代码,
/// 管理关闭行为/置顶、全局热键注册与前台应用检测。
class WindowControlService {
  WindowControlService._();

  static const MethodChannel _channel = MethodChannel(
    'emoji_manager/window_control',
  );

  /// 与 Win32 定义一致的 MOD_* 修饰键位掩码。
  static const int hotkeyModifierAlt = 0x1;
  static const int hotkeyModifierControl = 0x2;
  static const int hotkeyModifierShift = 0x4;
  static const int hotkeyModifierWin = 0x8;

  /// 仅 Windows 桌面平台支持。
  static bool get isSupported => !kIsWeb && Platform.isWindows;

  /// 应用窗口设置: 关闭按钮行为与是否置顶。
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

  /// 返回最近一个非本应用前台窗口的进程名 (小写, 如 `qq.exe`),
  /// 用于唤起时判断是否需要自动粘贴; 未知时返回 null。
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

  /// 注册/注销全局热键 ([modifiers] + [keyCode]);
  /// 返回是否注册成功 (可能因与其他软件冲突而失败)。
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
