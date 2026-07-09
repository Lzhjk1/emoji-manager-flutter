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

class EmojiManagerController extends ChangeNotifier {
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
  List<String> get categories => _itemsByCategory.keys.toList(growable: false);
  bool get hasData => _itemsByCategory.isNotEmpty;

  Map<String, EmojiItem> get categoryThumbnails {
    return <String, EmojiItem>{
      for (final entry in _itemsByCategory.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value.first,
    };
  }

  int get totalEmojiCount {
    return _itemsByCategory.values.fold<int>(
      0,
      (total, items) => total + items.length,
    );
  }

  List<EmojiItem> get visibleItems {
    final currentCategory = _selectedCategory;
    if (currentCategory == null) {
      return const [];
    }

    final source = _itemsByCategory[currentCategory] ?? const [];
    if (_searchQuery.isEmpty) {
      return source;
    }

    final keyword = _searchQuery.toLowerCase();
    return source.where((item) {
      return item.name.toLowerCase().contains(keyword) ||
          (item.remark?.toLowerCase().contains(keyword) ?? false);
    }).toList();
  }

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
    _rootPath = await _settingsService.loadRootPath();
    await _applyWindowSettings();

    if (_rootPath == null || _rootPath!.isEmpty) {
      _loadingMessage = null;
      notifyListeners();
      return;
    }

    final cached = await _cacheService.load(_rootPath!);
    if (cached != null) {
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
          !_itemsByCategory.containsKey(_selectedCategory)) {
        _selectedCategory =
            _itemsByCategory.isEmpty ? null : _itemsByCategory.keys.first;
      }
    }

    notifyListeners();
  }

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

  int? indexOfItemInCategory(String itemPath) {
    final entry = _findItemEntry(itemPath);
    return entry?.index;
  }

  int totalCountOfCategory(String category) {
    return _itemsByCategory[category]?.length ?? 0;
  }

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

  void selectCategory(String category) {
    if (_selectedCategory == category) {
      return;
    }
    _selectedCategory = category;
    notifyListeners();
  }

  void updateSearchQuery(String value) {
    if (_searchQuery == value.trim()) {
      return;
    }
    _searchQuery = value.trim();
    notifyListeners();
  }

  void clearSearch() {
    if (_searchQuery.isEmpty) {
      return;
    }
    _searchQuery = '';
    notifyListeners();
  }

  void _applyResult(Map<String, List<EmojiItem>> result) {
    _itemsByCategory = result;
    final categories = result.keys.toList(growable: false);
    if (_selectedCategory == null || !result.containsKey(_selectedCategory)) {
      _selectedCategory = categories.isEmpty ? null : categories.first;
    }
    _loading = false;
    _loadingMessage = null;
    notifyListeners();
  }

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

  Future<void> _applyWindowSettings() {
    return WindowControlService.applySettings(
      closeBehavior: _closeButtonBehavior,
      alwaysOnTop: _alwaysOnTop,
    );
  }
}

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
