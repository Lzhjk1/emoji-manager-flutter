import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/emoji_manager_controller.dart';
import '../image_card.dart';
import '../models/close_button_behavior.dart';
import '../models/emoji_item.dart';
import '../models/sort_order.dart';
import '../services/emoji_thumbnail_service.dart';
import '../services/platform_emoji_clipboard_service.dart';
import '../widgets/emoji_preview_dialog.dart';

class EmojiHomePage extends StatefulWidget {
  const EmojiHomePage({super.key});

  @override
  State<EmojiHomePage> createState() => _EmojiHomePageState();
}

class _EmojiHomePageState extends State<EmojiHomePage> {
  late final EmojiManagerController _controller;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _categoryScrollController = ScrollController();
  bool _showCompactStats = false;

  @override
  void initState() {
    super.initState();
    _controller = EmojiManagerController()..initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    _categoryScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Scaffold(
          body: Column(
            children: [
              if (_controller.loading && _controller.hasData)
                Column(
                  children: [
                    const LinearProgressIndicator(minHeight: 2),
                    if (_controller.loadingMessage != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        color: const Color(0xFF151A1F),
                        child: Text(
                          _controller.loadingMessage!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.white70,
                              ),
                        ),
                      ),
                  ],
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: _buildBody(context),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_controller.rootPath == null || _controller.rootPath!.isEmpty) {
      return _buildWelcomeState(context);
    }

    if (_controller.loading && !_controller.hasData) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (_controller.loadingMessage != null) ...[
              const SizedBox(height: 16),
              Text(
                _controller.loadingMessage!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white70,
                    ),
              ),
            ],
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTopBar(context),
        const SizedBox(height: 12),
        TextField(
          controller: _searchController,
          onChanged: _controller.updateSearchQuery,
          decoration: InputDecoration(
            hintText: '搜索表情文件名或备注',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _controller.searchQuery.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空搜索',
                    onPressed: () {
                      _searchController.clear();
                      _controller.clearSearch();
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        const SizedBox(height: 16),
        if (_controller.categories.isNotEmpty) _buildCategoryBar(context),
        if (_controller.categories.isNotEmpty) const SizedBox(height: 16),
        if (_controller.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _controller.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_controller.loadingMessage != null && !_controller.loading)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _controller.loadingMessage!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white60,
                  ),
            ),
          ),
        Expanded(
          child: Listener(
            onPointerSignal: _handlePointerSignal,
            child: _controller.visibleItems.isEmpty
                ? _buildEmptyCategoryState()
                : GridView.builder(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: _controller.gridThumbnailSize,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 0.9,
                    ),
                    itemCount: _controller.visibleItems.length,
                    itemBuilder: (context, index) {
                      final item = _controller.visibleItems[index];
                      return ImageCard(
                        width: double.infinity,
                        height: double.infinity,
                        imageProvider: _imageProviderFor(item),
                        title: item.name,
                        showText: false,
                        showBottomOverlay: false,
                        onTap: () => _handleEmojiTap(item),
                        onLongPress: () => _showPreview(item),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildWelcomeState(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '选择你的表情包根目录',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  '参考 Android 版规则：一级子目录作为分类，子目录内部递归扫描图片；根目录直接放置的图片归入“未分类”。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white70,
                      ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: _handlePickDirectory,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('选择表情包目录'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: null,
                      icon: const Icon(Icons.info_outline),
                      label: const Text('支持 PNG / JPG / GIF / WebP'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final selectedCount = _controller.visibleItems.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 980;
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '重新扫描',
              onPressed: _controller.rootPath == null ? null : _handleRescan,
              icon: const Icon(Icons.refresh),
            ),
            if (Platform.isWindows)
              IconButton(
                tooltip: _controller.alwaysOnTop ? '取消置顶' : '始终置顶',
                isSelected: _controller.alwaysOnTop,
                onPressed: () {
                  _controller.setAlwaysOnTop(!_controller.alwaysOnTop);
                },
                icon: const Icon(Icons.vertical_align_top),
                selectedIcon: const Icon(Icons.push_pin),
              ),
            PopupMenuButton<SortOrder>(
              tooltip: '排序方式',
              initialValue: _controller.sortOrder,
              onSelected: _controller.setSortOrder,
              itemBuilder: (context) {
                return SortOrder.values
                    .map(
                      (item) => PopupMenuItem<SortOrder>(
                        value: item,
                        child: Text(item.label),
                      ),
                    )
                    .toList();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sort),
                    const SizedBox(width: 6),
                    Text(_controller.sortOrder.label),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: '设置',
              onPressed: _showSettingsSheet,
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        );

        if (!compact) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildStatsWrap(selectedCount)),
              const SizedBox(width: 12),
              actions,
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: () {
                    setState(() {
                      _showCompactStats = !_showCompactStats;
                    });
                  },
                  icon: Icon(
                    _showCompactStats
                        ? Icons.visibility_off_outlined
                        : Icons.analytics_outlined,
                  ),
                  label: Text(_showCompactStats ? '隐藏统计' : '显示统计'),
                ),
                const Spacer(),
                actions,
              ],
            ),
            if (_showCompactStats) ...[
              const SizedBox(height: 12),
              _buildStatsWrap(selectedCount),
            ],
          ],
        );
      },
    );
  }

  Widget _buildStatsWrap(int selectedCount) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _StatChip(label: '分类', value: '${_controller.categories.length}'),
        _StatChip(label: '总表情', value: '${_controller.totalEmojiCount}'),
        _StatChip(label: '当前视图', value: '$selectedCount'),
        _StatChip(label: '排序', value: _controller.sortOrder.label),
        _StatChip(
          label: '缩略图',
          value: '${_controller.gridThumbnailSize.round()}',
        ),
      ],
    );
  }

  Widget _buildCategoryBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF11161C),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '分类',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Colors.white60,
                  letterSpacing: 0.6,
                ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 132,
            child: Scrollbar(
              controller: _categoryScrollController,
              thumbVisibility: true,
              notificationPredicate: (notification) => notification.depth == 0,
              child: Listener(
                onPointerSignal: _handleCategoryPointerSignal,
                child: ListView.separated(
                  controller: _categoryScrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: _controller.categories.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final category = _controller.categories[index];
                    final thumbnail = _controller.categoryThumbnails[category];
                    final isSelected = category == _controller.selectedCategory;

                    return _CategoryCard(
                      category: category,
                      imageProvider: _categoryImageProvider(thumbnail),
                      selected: isSelected,
                      onTap: () => _handleCategorySelection(category),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyCategoryState() {
    return Center(
      child: Text(
        _controller.searchQuery.isEmpty ? '当前分类没有可展示的图片' : '没有匹配到相关表情',
      ),
    );
  }

  Future<void> _handlePickDirectory() async {
    await _controller.pickRootDirectory();
    if (_searchController.text.isNotEmpty && _controller.searchQuery.isEmpty) {
      _searchController.clear();
    }
  }

  Future<void> _handleRescan() async {
    await _controller.rescan();
  }

  Future<void> _showSettingsSheet() async {
    final ignoreDirectoriesController = TextEditingController(
      text: _controller.ignoredDirectories.join(', '),
    );
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: const Color(0xFF17191C),
        constraints: const BoxConstraints(maxWidth: 720),
        builder: (context) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return SafeArea(
                top: false,
                child: FractionallySizedBox(
                  heightFactor: 0.92,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '设置',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '当前表情包目录',
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                color: Colors.white60,
                              ),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          _controller.rootPath ?? '尚未选择目录',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () async {
                                Navigator.of(context).pop();
                                await _handlePickDirectory();
                              },
                              icon: const Icon(Icons.folder_open),
                              label: const Text('选择目录'),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: _controller.rootPath == null
                                  ? null
                                  : _handleRescan,
                              icon: const Icon(Icons.refresh),
                              label: const Text('重新扫描'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Text(
                          '窗口',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        SegmentedButton<CloseButtonBehavior>(
                          segments: const [
                            ButtonSegment<CloseButtonBehavior>(
                              value: CloseButtonBehavior.exitApp,
                              label: Text('点击关闭即退出'),
                              icon: Icon(Icons.close),
                            ),
                            ButtonSegment<CloseButtonBehavior>(
                              value: CloseButtonBehavior.minimizeToTray,
                              label: Text('点击关闭缩到托盘'),
                              icon: Icon(Icons.minimize),
                            ),
                          ],
                          selected: <CloseButtonBehavior>{
                            _controller.closeButtonBehavior,
                          },
                          onSelectionChanged: (selection) {
                            if (selection.isNotEmpty) {
                              _controller.setCloseButtonBehavior(selection.first);
                            }
                          },
                        ),
                        const SizedBox(height: 24),
                        Text(
                          '扫描例外',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: ignoreDirectoriesController,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            hintText: '输入额外忽略目录名，使用逗号或换行分隔',
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '程序会自动忽略 `.sync` 和 `${EmojiThumbnailService.cacheDirectoryName}`。',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.white54,
                              ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            await _controller.setIgnoredDirectoriesFromText(
                              ignoreDirectoriesController.text,
                            );
                            if (!context.mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).hideCurrentSnackBar();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('已更新扫描例外并重新扫描'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.rule_folder_outlined),
                          label: const Text('保存扫描例外'),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '列表缩略图大小',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            Text(
                              '${_controller.gridThumbnailSize.round()}',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Colors.white70,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Slider(
                          min: 72,
                          max: 280,
                          divisions: 26,
                          value: _controller.gridThumbnailSize,
                          label: '${_controller.gridThumbnailSize.round()}',
                          onChanged: (value) {
                            _controller.setGridThumbnailSize(value);
                          },
                        ),
                        Text(
                          '桌面端支持 Ctrl + 鼠标滚轮实时调节缩略图大小。',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.white54,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      ignoreDirectoriesController.dispose();
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) {
      return;
    }

    final pressedKeys = HardwareKeyboard.instance.logicalKeysPressed;
    final isCtrlPressed =
        pressedKeys.contains(LogicalKeyboardKey.controlLeft) ||
        pressedKeys.contains(LogicalKeyboardKey.controlRight);
    if (!isCtrlPressed) {
      return;
    }

    final nextValue = _controller.gridThumbnailSize +
        (event.scrollDelta.dy > 0 ? -12 : 12);
    _controller.setGridThumbnailSize(nextValue);
  }

  void _handleCategoryPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_categoryScrollController.hasClients) {
      return;
    }

    final nextOffset = (_categoryScrollController.offset + event.scrollDelta.dy)
        .clamp(
          _categoryScrollController.position.minScrollExtent,
          _categoryScrollController.position.maxScrollExtent,
        );
    _categoryScrollController.jumpTo(nextOffset);
  }

  Future<void> _handleEmojiTap(EmojiItem item) async {
    final copied = await PlatformEmojiClipboardService.copyFile(item.path);
    if (!mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          copied ? '已复制文件到剪贴板' : '复制失败：无法写入文件到剪贴板',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  ImageProvider<Object>? _imageProviderFor(EmojiItem item) {
    final thumbnailPath = _thumbnailPathFor(item);
    if (thumbnailPath == null) {
      if (item.mimeType == 'image/gif') {
        return FileImage(File(item.path));
      }
      return null;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final targetSize = math.min(
      (((_controller.gridThumbnailSize + 16) * dpr).round()),
      EmojiThumbnailService.thumbnailMaxSize,
    );
    return ResizeImage(
      FileImage(File(thumbnailPath)),
      width: targetSize,
      height: targetSize,
    );
  }

  ImageProvider<Object>? _categoryImageProvider(EmojiItem? item) {
    if (item == null) {
      return null;
    }
    final thumbnailPath = _thumbnailPathFor(item);
    if (thumbnailPath == null) {
      if (item.mimeType == 'image/gif') {
        return FileImage(File(item.path));
      }
      return null;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final targetSize = math.min((96 * dpr).round(), EmojiThumbnailService.thumbnailMaxSize);
    return ResizeImage(
      FileImage(File(thumbnailPath)),
      width: targetSize,
      height: targetSize,
    );
  }

  String? _thumbnailPathFor(EmojiItem? item) {
    if (item == null) {
      return null;
    }
    final thumbnailPath = item.thumbnailPath;
    if (thumbnailPath != null && File(thumbnailPath).existsSync()) {
      return thumbnailPath;
    }
    return null;
  }

  void _handleCategorySelection(String category) {
    if (_controller.selectedCategory == category) {
      return;
    }
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
    _controller.selectCategory(category);
  }

  Future<void> _showPreview(EmojiItem item) async {
    final currentIndex = _controller.indexOfItemInCategory(item.path) ?? 0;
    final totalCount = _controller.totalCountOfCategory(item.category);
    await showDialog<void>(
      context: context,
      builder: (context) => EmojiPreviewDialog(
        item: item,
        currentIndex: currentIndex,
        totalCount: totalCount,
        onSaveRemark: (remark) => _controller.saveRemark(item.path, remark),
        onMoveUp: () => _controller.moveItemUp(item.path),
        onMoveDown: () => _controller.moveItemDown(item.path),
        onMoveToStart: () => _controller.moveItemToStart(item.path),
        onMoveToEnd: () => _controller.moveItemToEnd(item.path),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF1E2227),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: '$label  ',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white60,
                      fontSize: 12,
                    ),
              ),
              TextSpan(
                text: value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.category,
    required this.imageProvider,
    required this.selected,
    required this.onTap,
  });

  final String category;
  final ImageProvider<Object>? imageProvider;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Ink(
          width: 112,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1D21),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : Colors.white12,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox.expand(
                      child: imageProvider == null
                          ? const ColoredBox(
                              color: Color(0xFF30343A),
                              child: Icon(
                                Icons.folder_copy_outlined,
                                color: Colors.white38,
                                size: 32,
                              ),
                            )
                          : Image(
                              image: imageProvider!,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return const ColoredBox(
                                  color: Color(0xFF30343A),
                                  child: Icon(
                                    Icons.folder_copy_outlined,
                                    color: Colors.white38,
                                    size: 32,
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: selected ? theme.colorScheme.primary : Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
