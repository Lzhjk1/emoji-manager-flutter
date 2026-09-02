import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../models/close_button_behavior.dart';
import '../models/emoji_item.dart';
import '../models/emoji_scan_result.dart';
import '../models/sort_order.dart';
import '../services/emoji_cache_service.dart';
import '../services/emoji_repository.dart';
import '../services/emoji_settings_service.dart';
import '../services/window_control_service.dart';

/// 应用状态中枢 (Controller 层)。
///
/// 持有表情库数据、当前选中分类、搜索词、排序方式与各设置项,
/// 调用 services 层完成扫描/导入/删除/排序等操作后通过 [notifyListeners]
/// 通知 UI 重建。UI 层 (emoji_home_page) 只与该控制器交互。
class EmojiManagerController extends ChangeNotifier {
  /// "全部表情"虚拟视图 (聚合所有分类, 无对应磁盘目录)。
  static const String allCategoryView = '__all__';

  /// "最近使用"虚拟视图 (按使用记录排序)。
  static const String recentCategoryView = '__recent__';

  /// 最近使用记录条数上限。
  static const int _recentUsageLimit = 200;

  EmojiManagerController({
    EmojiRepository? repository,
    EmojiCacheService? cacheService,
    EmojiSettingsService? settingsService,
  })  : _repository = repository ?? EmojiRepository(),
        _cacheService = cacheService ?? EmojiCacheService(),
        _settingsService = settingsService ?? EmojiSettingsService();

  final EmojiRepository _repository;
  final EmojiCacheService _cacheService;
  final EmojiSettingsService _settingsService;

  bool _initialized = false;
  bool _loading = false;
  String? _rootPath;
  String? _selectedCategory;
  String _searchQuery = '';
  String? _errorMessage;
  String? _loadingMessage;
  SortOrder _sortOrder = SortOrder.byOrder;
  double _gridThumbnailSize = 180;
  CloseButtonBehavior _closeButtonBehavior = CloseButtonBehavior.exitApp;
  bool _alwaysOnTop = false;
  List<String> _ignoredDirectories = const [];
  Map<String, List<EmojiItem>> _itemsByCategory = {};
  Map<String, CategoryMetadata> _categoryMetadata = {};
  List<String> _recentUsage = [];
  List<String> _autoPasteProcesses = const [];
  bool _hotkeyEnabled = true;
  int _hotkeyModifiers = WindowControlService.hotkeyModifierControl |
      WindowControlService.hotkeyModifierShift;
  int _hotkeyKeyCode = 0x56; // 'V'

  bool get loading => _loading;
  String? get rootPath => _rootPath;
  String? get selectedCategory => _selectedCategory;
  String get searchQuery => _searchQuery;
  String? get errorMessage => _errorMessage;
  String? get loadingMessage => _loadingMessage;
  SortOrder get sortOrder => _sortOrder;
  double get gridThumbnailSize => _gridThumbnailSize;
  CloseButtonBehavior get closeButtonBehavior => _closeButtonBehavior;
  bool get alwaysOnTop => _alwaysOnTop;
  List<String> get ignoredDirectories =>
      List<String>.unmodifiable(_ignoredDirectories);
  List<String> get autoPasteProcesses =>
      List<String>.unmodifiable(_autoPasteProcesses);
  bool get hotkeyEnabled => _hotkeyEnabled;
  int get hotkeyModifiers => _hotkeyModifiers;
  int get hotkeyKeyCode => _hotkeyKeyCode;
  List<String> get categories => _itemsByCategory.keys.toList(growable: false);
  bool get hasData => _itemsByCategory.isNotEmpty;

  /// 每个分类取第一张图, 作为分类卡片的封面缩略图。
  Map<String, EmojiItem> get categoryThumbnails {
    return <String, EmojiItem>{
      for (final entry in _itemsByCategory.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value.first,
    };
  }

  /// 表情总数 (所有分类求和)。
  int get totalEmojiCount {
    return _itemsByCategory.values.fold<int>(
      0,
      (total, items) => total + items.length,
    );
  }

  EmojiItem? get firstItemOverall {
    for (final items in _itemsByCategory.values) {
      if (items.isNotEmpty) {
        return items.first;
      }
    }
    return null;
  }

  /// "最近使用"视图的封面缩略图 (最近一次使用的表情)。
  EmojiItem? get recentViewThumbnail {
    final recent = recentItems;
    return recent.isEmpty ? null : recent.first;
  }

  /// 按最近使用记录的顺序, 从当前数据中捞出仍然存在的表情。
  List<EmojiItem> get recentItems {
    final index = <String, EmojiItem>{
      for (final items in _itemsByCategory.values)
        for (final item in items) item.path: item,
    };
    return [
      for (final path in _recentUsage)
        if (index[path] != null) index[path]!,
    ];
  }

  /// 当前视图是否为虚拟视图 (全部/最近使用)。
  bool get _isSpecialView {
    return _selectedCategory == allCategoryView ||
        _selectedCategory == recentCategoryView;
  }

  /// 当前视图应显示的表情列表:
  /// 全部视图聚合所有分类, 最近使用视图按使用记录, 其余取对应分类;
  /// 再按搜索词过滤 (匹配名称或备注)。
  List<EmojiItem> get visibleItems {
    final currentCategory = _selectedCategory;
    if (currentCategory == null) {
      return const [];
    }

    final List<EmojiItem> source;
    if (currentCategory == allCategoryView) {
      source = [
        for (final items in _itemsByCategory.values) ...items,
      ];
    } else if (currentCategory == recentCategoryView) {
      source = recentItems;
    } else {
      source = _itemsByCategory[currentCategory] ?? const [];
    }
    if (_searchQuery.isEmpty) {
      return source;
    }

    final keyword = _searchQuery.toLowerCase();
    return source.where((item) {
      return item.name.toLowerCase().contains(keyword) ||
          (item.remark?.toLowerCase().contains(keyword) ?? false);
    }).toList();
  }

  /// 应用启动初始化: 恢复设置、应用窗口/热键配置,
  /// 优先用缓存数据快速呈现, 再后台重新扫描刷新。
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;

    _sortOrder = await _settingsService.loadSortOrder();
    _gridThumbnailSize = await _settingsService.loadGridThumbnailSize();
    _closeButtonBehavior = await _settingsService.loadCloseButtonBehavior();
    _alwaysOnTop = await _settingsService.loadAlwaysOnTop();
    _ignoredDirectories = await _settingsService.loadIgnoredDirectories();
    _recentUsage = await _settingsService.loadRecentUsage();
    _autoPasteProcesses = await _settingsService.loadAutoPasteProcesses();
    _hotkeyEnabled = await _settingsService.loadHotkeyEnabled();
    _hotkeyModifiers = await _settingsService.loadHotkeyModifiers();
    _hotkeyKeyCode = await _settingsService.loadHotkeyKeyCode();
    _rootPath = await _settingsService.loadRootPath();
    await _applyWindowSettings();
    await _applyHotkeySettings();

    if (_rootPath == null || _rootPath!.isEmpty) {
      _loadingMessage = null;
      notifyListeners();
      return;
    }

    final cached = await _cacheService.load(_rootPath!);
    if (cached != null) {
      // 缓存命中: 先立即呈现缓存数据, 再异步重新扫描保证内容最新。
      _categoryMetadata = cached.categoryMetadata;
      _applyResult(
        await _repository.sortItemsByCategory(
          _rootPath!,
          cached.itemsByCategory,
          _sortOrder,
        ),
      );
      unawaited(
        rescan(
          loadingMessage: '正在扫描并生成缩略图，首次加载可能稍慢',
        ),
      );
      return;
    }

    await rescan(
      loadingMessage: '正在扫描并生成缩略图，首次加载可能稍慢',
    );
  }

  /// 通过系统对话框选择表情库根目录, 重置状态后扫描。
  Future<void> pickRootDirectory() async {
    final selectedPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择表情包根目录',
    );
    if (selectedPath == null || selectedPath.isEmpty) {
      return;
    }

    _rootPath = selectedPath;
    _selectedCategory = null;
    _errorMessage = null;
    _searchQuery = '';
    _itemsByCategory = {};
    _categoryMetadata = {};
    notifyListeners();

    await _settingsService.saveRootPath(selectedPath);
    final cached = await _cacheService.load(selectedPath);
    if (cached != null) {
      _categoryMetadata = cached.categoryMetadata;
      _applyResult(
        await _repository.sortItemsByCategory(
          selectedPath,
          cached.itemsByCategory,
          _sortOrder,
        ),
      );
    }

    await rescan(
      loadingMessage: '正在扫描并生成缩略图，首次加载可能稍慢',
    );
  }

  /// 重新扫描表情库, 更新数据并写回缓存; 扫描出错时记录错误信息。
  Future<void> rescan({
    bool showBusyIndicator = true,
    String? loadingMessage,
  }) async {
    final currentRootPath = _rootPath;
    if (currentRootPath == null || currentRootPath.isEmpty) {
      return;
    }

    _loading = showBusyIndicator;
    _errorMessage = null;
    _loadingMessage =
        showBusyIndicator ? (loadingMessage ?? '正在扫描并更新缩略图...') : null;
    notifyListeners();

    try {
      final result = await _repository.scanWithMetadata(
        currentRootPath,
        ignoredDirectoryNames: _ignoredDirectories.toSet(),
      );
      _categoryMetadata = result.categoryMetadata;
      final sorted = await _repository.sortItemsByCategory(
        currentRootPath,
        result.itemsByCategory,
        _sortOrder,
      );
      _applyResult(sorted);
      await _cacheService.save(
        currentRootPath,
        EmojiScanResult(
          itemsByCategory: sorted,
          categoryMetadata: _categoryMetadata,
        ),
      );
    } catch (error) {
      _loading = false;
      _loadingMessage = null;
      _errorMessage = error.toString();
      notifyListeners();
    }
  }

  /// 切换排序方式: 持久化后对现有数据重新排序。
  Future<void> setSortOrder(SortOrder sortOrder) async {
    if (_sortOrder == sortOrder) {
      return;
    }

    _sortOrder = sortOrder;
    await _settingsService.saveSortOrder(sortOrder);

    final currentRootPath = _rootPath;
    if (currentRootPath != null && _itemsByCategory.isNotEmpty) {
      _itemsByCategory = await _repository.sortItemsByCategory(
        currentRootPath,
        _itemsByCategory,
        _sortOrder,
      );
      if (_selectedCategory != null &&
          !_isSpecialView &&
          !_itemsByCategory.containsKey(_selectedCategory)) {
        _selectedCategory =
            _itemsByCategory.isEmpty ? null : _itemsByCategory.keys.first;
      }
    }

    notifyListeners();
  }

  /// 调整网格缩略图边长 (限制在 72~280 之间)。
  Future<void> setGridThumbnailSize(double size) async {
    final normalizedSize = size.clamp(72, 280).toDouble();
    if ((_gridThumbnailSize - normalizedSize).abs() < 0.001) {
      return;
    }

    _gridThumbnailSize = normalizedSize;
    await _settingsService.saveGridThumbnailSize(normalizedSize);
    notifyListeners();
  }

  Future<void> setCloseButtonBehavior(CloseButtonBehavior behavior) async {
    if (_closeButtonBehavior == behavior) {
      return;
    }

    _closeButtonBehavior = behavior;
    await _settingsService.saveCloseButtonBehavior(behavior);
    await _applyWindowSettings();
    notifyListeners();
  }

  Future<void> setAlwaysOnTop(bool value) async {
    if (_alwaysOnTop == value) {
      return;
    }

    _alwaysOnTop = value;
    await _settingsService.saveAlwaysOnTop(value);
    await _applyWindowSettings();
    notifyListeners();
  }

  /// 从设置页文本解析忽略目录列表 (按换行/逗号/分号切分) 并触发重扫。
  Future<void> setIgnoredDirectoriesFromText(String value) async {
    final normalized = value
        .split(RegExp(r'[\n,;]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    if (listEquals(_ignoredDirectories, normalized)) {
      return;
    }

    _ignoredDirectories = normalized;
    await _settingsService.saveIgnoredDirectories(normalized);
    await rescan();
  }

  /// 从设置页文本解析自动粘贴目标进程列表并持久化。
  Future<void> setAutoPasteProcessesFromText(String value) async {
    final normalized = value
        .split(RegExp(r'[\n,;]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    if (listEquals(_autoPasteProcesses, normalized)) {
      return;
    }

    _autoPasteProcesses = normalized;
    await _settingsService.saveAutoPasteProcesses(normalized);
    notifyListeners();
  }

  /// 判断给定进程名是否在自动粘贴目标列表中 (忽略大小写与 .exe 后缀)。
  bool matchesAutoPasteTarget(String processName) {
    if (processName.isEmpty || _autoPasteProcesses.isEmpty) {
      return false;
    }
    final target = normalizeProcessName(processName);
    if (target.isEmpty) {
      return false;
    }
    return _autoPasteProcesses
        .any((entry) => normalizeProcessName(entry) == target);
  }

  /// 进程名规范化: 去空白、转小写、去掉 .exe 后缀, 便于比较。
  static String normalizeProcessName(String name) {
    var value = name.trim().toLowerCase();
    if (value.endsWith('.exe')) {
      value = value.substring(0, value.length - 4);
    }
    return value;
  }

  /// 启用/禁用全局热键并立即向原生层重新注册。
  Future<void> setHotkeyEnabled(bool enabled) async {
    if (_hotkeyEnabled == enabled) {
      return;
    }
    _hotkeyEnabled = enabled;
    await _settingsService.saveHotkeyEnabled(enabled);
    await _applyHotkeySettings();
    notifyListeners();
  }

  /// 更新全局热键组合 (修饰键 + 主键) 并重新注册。
  Future<void> setHotkeyBinding({
    required int modifiers,
    required int keyCode,
  }) async {
    if (_hotkeyModifiers == modifiers && _hotkeyKeyCode == keyCode) {
      return;
    }
    _hotkeyModifiers = modifiers;
    _hotkeyKeyCode = keyCode;
    await _settingsService.saveHotkeyModifiers(modifiers);
    await _settingsService.saveHotkeyKeyCode(keyCode);
    await _applyHotkeySettings();
    notifyListeners();
  }

  /// 把当前热键配置应用到原生层 (注册或注销)。
  Future<void> _applyHotkeySettings() {
    if (!WindowControlService.isSupported) {
      return Future.value();
    }
    return WindowControlService.setHotkey(
      enabled: _hotkeyEnabled,
      modifiers: _hotkeyModifiers,
      keyCode: _hotkeyKeyCode,
    );
  }

  /// 查找表情在当前视图中的索引, 用于预览弹窗的左右翻页;
  /// 找不到时返回 null。
  int? indexOfItemInCategory(String itemPath) {
    if (_selectedCategory == allCategoryView) {
      var offset = 0;
      for (final items in _itemsByCategory.values) {
        final index = items.indexWhere((item) => item.path == itemPath);
        if (index >= 0) {
          return offset + index;
        }
        offset += items.length;
      }
      return null;
    }
    if (_selectedCategory == recentCategoryView) {
      final index =
          recentItems.indexWhere((item) => item.path == itemPath);
      return index >= 0 ? index : null;
    }
    final entry = _findItemEntry(itemPath);
    return entry?.index;
  }

  /// 指定视图的表情数量 (含虚拟视图)。
  int totalCountOfCategory(String category) {
    if (category == allCategoryView) {
      return totalEmojiCount;
    }
    if (category == recentCategoryView) {
      return recentItems.length;
    }
    return _itemsByCategory[category]?.length ?? 0;
  }

  /// 记录一次使用: 把表情移到最近使用列表头部并持久化 (超过上限裁剪)。
  Future<void> recordUsage(String itemPath) async {
    _recentUsage = [
      itemPath,
      ..._recentUsage.where((path) => path != itemPath),
    ];
    if (_recentUsage.length > _recentUsageLimit) {
      _recentUsage = _recentUsage.sublist(0, _recentUsageLimit);
    }
    await _settingsService.saveRecentUsage(_recentUsage);
    if (_selectedCategory == recentCategoryView) {
      notifyListeners();
    }
  }

  /// 当前视图是否可接收拖入的图片。
  /// 虚拟视图 (最近使用/全部) 没有对应的磁盘目录, 不能接收。
  bool get canAcceptDroppedImages {
    final category = _selectedCategory;
    return category != null &&
        !_isSpecialView &&
        _rootPath != null &&
        _rootPath!.isNotEmpty;
  }

  /// 把拖入的文件/目录导入当前选中分类, 并把新导入的插入到列表头部。
  /// 返回导入结果; 当前视图不可接收或 paths 为空时返回 null,
  /// 由调用方提示用户。
  Future<ImportResult?> addImagesToCurrentCategory(List<String> paths) async {
    final category = _selectedCategory;
    final currentRootPath = _rootPath;
    if (!canAcceptDroppedImages || paths.isEmpty) {
      return null;
    }

    final result = await _repository.importDroppedPaths(
      rootPath: currentRootPath!,
      category: category!,
      paths: paths,
    );
    if (result.imported.isEmpty) {
      return result;
    }

    final existing = _itemsByCategory[category] ?? const <EmojiItem>[];
    final existingPaths = existing.map((item) => item.path).toSet();
    final fresh =
        result.imported.where((item) => !existingPaths.contains(item.path));
    _itemsByCategory[category] = [...fresh, ...existing];
    await _saveCache();
    notifyListeners();
    return result;
  }

  /// 删除图片文件 (连同缩略图与元数据条目), 并从内存状态中移除;
  /// 找不到条目或删除失败时返回 false。
  Future<bool> deleteItem(String itemPath) async {
    final entry = _findItemEntry(itemPath);
    final rootPath = _rootPath;
    if (entry == null || rootPath == null) {
      return false;
    }

    final deleted = await _repository.deleteImage(
      rootPath: rootPath,
      category: entry.category,
      item: entry.items[entry.index],
    );
    if (!deleted) {
      return false;
    }

    final items = [...entry.items]..removeAt(entry.index);
    if (items.isEmpty) {
      _itemsByCategory.remove(entry.category);
      if (_selectedCategory == entry.category) {
        _selectedCategory = _itemsByCategory.isEmpty
            ? null
            : _itemsByCategory.keys.first;
      }
    } else {
      _itemsByCategory[entry.category] = items;
    }

    if (_recentUsage.contains(itemPath)) {
      _recentUsage =
          _recentUsage.where((path) => path != itemPath).toList();
      await _settingsService.saveRecentUsage(_recentUsage);
    }
    await _saveCache();
    notifyListeners();
    return true;
  }

  /// 重新生成单张图片的缩略图并更新内存状态; 失败返回 false。
  Future<bool> refreshThumbnail(String itemPath) async {
    final entry = _findItemEntry(itemPath);
    final rootPath = _rootPath;
    if (entry == null || rootPath == null) {
      return false;
    }

    final updated = await _repository.refreshThumbnail(
      rootPath,
      entry.items[entry.index],
    );
    if (updated == null) {
      return false;
    }

    final items = [...entry.items];
    items[entry.index] = updated;
    _itemsByCategory[entry.category] = items;
    await _saveCache();
    notifyListeners();
    return true;
  }

  /// 保存图片备注 (空串表示清除), 同步内存状态与缓存。
  Future<void> saveRemark(String itemPath, String remark) async {
    final entry = _findItemEntry(itemPath);
    if (entry == null) {
      return;
    }

    await _repository.saveImageRemark(imagePath: itemPath, remark: remark);
    final items = [...entry.items];
    items[entry.index] = entry.items[entry.index].copyWith(
      remark: remark.trim(),
      clearRemark: remark.trim().isEmpty,
    );
    _itemsByCategory[entry.category] = items;
    await _saveCache();
    notifyListeners();
  }

  /// 移动表情位置 (上移/下移/置顶/置底入口)。
  Future<void> moveItemUp(String itemPath) async {
    await _moveItem(itemPath, offset: -1);
  }

  Future<void> moveItemDown(String itemPath) async {
    await _moveItem(itemPath, offset: 1);
  }

  Future<void> moveItemToStart(String itemPath) async {
    await _moveItem(itemPath, targetIndex: 0);
  }

  Future<void> moveItemToEnd(String itemPath) async {
    final entry = _findItemEntry(itemPath);
    if (entry == null) {
      return;
    }
    await _moveItem(itemPath, targetIndex: entry.items.length - 1);
  }

  /// 选择分类视图。
  void selectCategory(String category) {
    if (_selectedCategory == category) {
      return;
    }
    _selectedCategory = category;
    notifyListeners();
  }

  /// 更新搜索词 (自动去首尾空白)。
  void updateSearchQuery(String value) {
    if (_searchQuery == value.trim()) {
      return;
    }
    _searchQuery = value.trim();
    notifyListeners();
  }

  /// 清空搜索词。
  void clearSearch() {
    if (_searchQuery.isEmpty) {
      return;
    }
    _searchQuery = '';
    notifyListeners();
  }

  /// 应用扫描/排序结果, 结束加载态, 必要时修正选中分类。
  void _applyResult(Map<String, List<EmojiItem>> result) {
    _itemsByCategory = result;
    final categories = result.keys.toList(growable: false);
    if (!_isSpecialView &&
        (_selectedCategory == null || !result.containsKey(_selectedCategory))) {
      _selectedCategory = categories.isEmpty ? null : categories.first;
    }
    _loading = false;
    _loadingMessage = null;
    notifyListeners();
  }

  /// 移动表情到新位置, 把当前顺序写回顺序文件;
  /// 手动排序会强制把排序方式切回"按顺序文件"。
  Future<void> _moveItem(
    String itemPath, {
    int? offset,
    int? targetIndex,
  }) async {
    final entry = _findItemEntry(itemPath);
    final currentRootPath = _rootPath;
    if (entry == null || currentRootPath == null) {
      return;
    }

    final items = [...entry.items];
    final fromIndex = entry.index;
    var toIndex = targetIndex ?? (fromIndex + (offset ?? 0));
    toIndex = toIndex.clamp(0, items.length - 1);
    if (fromIndex == toIndex) {
      return;
    }

    final movingItem = items.removeAt(fromIndex);
    items.insert(toIndex, movingItem);
    _itemsByCategory[entry.category] = items;

    if (_sortOrder != SortOrder.byOrder) {
      _sortOrder = SortOrder.byOrder;
      await _settingsService.saveSortOrder(_sortOrder);
    }

    await _repository.saveOrderForCategory(
      rootPath: currentRootPath,
      category: entry.category,
      items: items,
    );
    await _saveCache();
    notifyListeners();
  }

  /// 在所有分类中按路径查找表情, 返回其所在分类与索引。
  _ItemEntry? _findItemEntry(String itemPath) {
    for (final entry in _itemsByCategory.entries) {
      final index = entry.value.indexWhere((item) => item.path == itemPath);
      if (index >= 0) {
        return _ItemEntry(
          category: entry.key,
          items: entry.value,
          index: index,
        );
      }
    }
    return null;
  }

  /// 把当前内存数据写回应用级缓存。
  Future<void> _saveCache() async {
    final currentRootPath = _rootPath;
    if (currentRootPath == null) {
      return;
    }
    await _cacheService.save(
      currentRootPath,
      EmojiScanResult(
        itemsByCategory: _itemsByCategory,
        categoryMetadata: _categoryMetadata,
      ),
    );
  }

  /// 把窗口设置 (关闭行为/置顶) 应用到原生层。
  Future<void> _applyWindowSettings() {
    return WindowControlService.applySettings(
      closeBehavior: _closeButtonBehavior,
      alwaysOnTop: _alwaysOnTop,
    );
  }
}

/// 表情在 `_itemsByCategory` 中的定位信息 (分类名 + 列表 + 索引)。
class _ItemEntry {
  const _ItemEntry({
    required this.category,
    required this.items,
    required this.index,
  });

  final String category;
  final List<EmojiItem> items;
  final int index;
}
