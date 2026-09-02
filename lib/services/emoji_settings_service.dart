import 'package:shared_preferences/shared_preferences.dart';

import '../models/close_button_behavior.dart';
import '../models/sort_order.dart';

/// 用户设置的持久化层, 基于 SharedPreferences 封装各设置项的读写。
///
/// 覆盖: 表情库根路径、排序方式、网格缩略图尺寸、关闭按钮行为、
/// 窗口置顶、忽略目录、最近使用记录 (上限 200 条, 由调用方裁剪)、
/// 自动粘贴目标进程列表与全局热键配置。
class EmojiSettingsService {
  static const _rootPathKey = 'emoji_root_path';
  static const _sortOrderKey = 'emoji_sort_order';
  static const _gridThumbnailSizeKey = 'emoji_grid_thumbnail_size';
  static const _closeButtonBehaviorKey = 'close_button_behavior';
  static const _alwaysOnTopKey = 'always_on_top';
  static const _ignoredDirectoriesKey = 'ignored_directories';
  static const _recentUsageKey = 'emoji_recent_usage';
  static const _autoPasteProcessesKey = 'auto_paste_processes';
  static const _hotkeyEnabledKey = 'hotkey_enabled';
  static const _hotkeyModifiersKey = 'hotkey_modifiers';
  static const _hotkeyKeyCodeKey = 'hotkey_key_code';

  Future<String?> loadRootPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_rootPathKey);
  }

  Future<void> saveRootPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_rootPathKey, path);
  }

  Future<SortOrder> loadSortOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return SortOrder.fromStorage(prefs.getString(_sortOrderKey));
  }

  Future<void> saveSortOrder(SortOrder sortOrder) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sortOrderKey, sortOrder.storageValue);
  }

  Future<double> loadGridThumbnailSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_gridThumbnailSizeKey) ?? 180;
  }

  Future<void> saveGridThumbnailSize(double size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_gridThumbnailSizeKey, size);
  }

  Future<CloseButtonBehavior> loadCloseButtonBehavior() async {
    final prefs = await SharedPreferences.getInstance();
    return CloseButtonBehavior.fromStorage(
      prefs.getString(_closeButtonBehaviorKey),
    );
  }

  Future<void> saveCloseButtonBehavior(CloseButtonBehavior behavior) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_closeButtonBehaviorKey, behavior.storageValue);
  }

  Future<bool> loadAlwaysOnTop() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_alwaysOnTopKey) ?? false;
  }

  Future<void> saveAlwaysOnTop(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_alwaysOnTopKey, value);
  }

  Future<List<String>> loadIgnoredDirectories() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_ignoredDirectoriesKey) ?? const [];
  }

  Future<void> saveIgnoredDirectories(List<String> directories) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_ignoredDirectoriesKey, directories);
  }

  Future<List<String>> loadRecentUsage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_recentUsageKey) ?? const [];
  }

  Future<void> saveRecentUsage(List<String> paths) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentUsageKey, paths);
  }

  /// 自动粘贴目标进程列表, 默认只有 QQ.exe。
  Future<List<String>> loadAutoPasteProcesses() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_autoPasteProcessesKey) ?? const ['QQ.exe'];
  }

  Future<void> saveAutoPasteProcesses(List<String> processes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_autoPasteProcessesKey, processes);
  }

  Future<bool> loadHotkeyEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hotkeyEnabledKey) ?? true;
  }

  Future<void> saveHotkeyEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hotkeyEnabledKey, value);
  }

  /// 热键修饰键位掩码, 默认 Ctrl + Shift (0x2 | 0x4)。
  Future<int> loadHotkeyModifiers() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_hotkeyModifiersKey) ?? 0x6; // Ctrl + Shift
  }

  Future<void> saveHotkeyModifiers(int modifiers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_hotkeyModifiersKey, modifiers);
  }

  /// 热键主键的虚拟键码, 默认 'V' (0x56)。
  Future<int> loadHotkeyKeyCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_hotkeyKeyCodeKey) ?? 0x56; // 'V'
  }

  Future<void> saveHotkeyKeyCode(int keyCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_hotkeyKeyCodeKey, keyCode);
  }
}
