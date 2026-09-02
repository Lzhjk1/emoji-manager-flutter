import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/emoji_manager_controller.dart';
import '../image_card.dart';
import '../models/close_button_behavior.dart';
import '../models/emoji_item.dart';
import '../models/emoji_scan_result.dart';
import '../models/sort_order.dart';
import '../services/emoji_thumbnail_service.dart';
import '../services/platform_emoji_clipboard_service.dart';
import '../services/window_control_service.dart';
import '../widgets/emoji_preview_dialog.dart';

/// 主页面 (View 层)。
class EmojiHomePage extends StatefulWidget {
  const EmojiHomePage({super.key});

  @override
  State<EmojiHomePage> createState() => _EmojiHomePageState();
}

/// 主页面状态: 通过 [AnimatedBuilder] 监听 Controller,
/// 组合顶栏 (搜索/排序/置顶/设置)、分类栏与表情网格。
class _EmojiHomePageState extends State<EmojiHomePage> {
  late final EmojiManagerController _controller;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _categoryScrollController = ScrollController();

  /// 是否有内容正在拖入悬浮 (用于显示拖放遮罩)。
  bool _dragging = false;

  // ---- 按压手势状态机: 按下直接拖动 = 重排序; 按住不动稍久 = 放大预览。----
  /// 放大预览触发延时 (按住基本不动)。
  static const _zoomActivationDelay = Duration(milliseconds: 200);
  /// 判定"开始拖动"的位移阈值 (逻辑像素), 超过即进入拖拽并取消放大。
  static const _dragStartSlop = 8.0;

  Timer? _zoomActivationTimer;
  bool _dragActive = false;
  bool _zoomActive = false;
  Offset? _pressStartPosition;
  String? _dragPath;
  EmojiItem? _zoomItem;
  /// 本次按压激活过拖拽/放大模式, 松手后需吞掉随之而来的 tap。
  bool _pressActivatedMode = false;

  @override
  void initState() {
    super.initState();
    _controller = EmojiManagerController()..initialize();
  }

  @override
  void dispose() {
    _zoomActivationTimer?.cancel();
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
          body: Stack(
            children: [
              Column(
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
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
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
              if (_controller.healReport != null)
                Positioned(
                  top: 12,
                  left: 20,
                  right: 20,
                  child: _HealReportBanner(
                    report: _controller.healReport!,
                    onDismiss: _controller.dismissHealReport,
                  ),
                ),
              if (_zoomActive && _zoomItem != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: _buildZoomOverlay(_zoomItem!),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 页面主体: 未选目录时显示欢迎页, 首次加载显示进度,
  /// 否则显示 顶栏 + 分类栏 + 表情网格。
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
          child: DropTarget(
            onDragEntered: (_) {
              if (mounted) {
                setState(() => _dragging = true);
              }
            },
            onDragExited: (_) {
              if (mounted) {
                setState(() => _dragging = false);
              }
            },
            onDragDone: _handleImageDrop,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerSignal: _handlePointerSignal,
                    onPointerUp: (_) => _finishPress(),
                    onPointerCancel: (_) => _finishPress(),
                    child: _controller.visibleItems.isEmpty
                        ? _buildEmptyCategoryState()
                        : GridView.builder(
                            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: _controller.gridThumbnailSize,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                              childAspectRatio: 1.0,
                            ),
                            itemCount: _controller.visibleItems.length,
                            itemBuilder: (context, index) =>
                                _buildGridCard(
                                  context,
                                  _controller.visibleItems[index],
                                ),
                          ),
                  ),
                ),
                if (_dragging) _buildDropOverlay(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 网格卡片: 包裹 MouseRegion (放大时悬停切换大图) 与 Listener
  /// (按下/移动事件驱动 拖拽重排 或 放大预览 状态机)。
  Widget _buildGridCard(BuildContext context, EmojiItem item) {
    final card = Tooltip(
      message: item.name,
      excludeFromSemantics: true,
      child: MouseRegion(
        cursor:
            _dragActive ? SystemMouseCursors.move : SystemMouseCursors.click,
        // 指针按下后 hit test 锁定在起始卡片, move 事件不会派发给其它卡片;
        // 拖拽换位与放大切换都依赖 MouseTracker 的 onEnter (每次移动重新命中)。
        onEnter: (_) => _handleItemHover(item),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) => _handleItemPointerDown(item, event),
          onPointerMove: (event) => _handleItemPointerMove(item, event.position),
          child: ImageCard(
            width: double.infinity,
            height: double.infinity,
            imageProvider: _imageProviderFor(item),
            title: item.name,
            showText: false,
            showBottomOverlay: false,
            selected: _dragActive && _dragPath == item.path,
            trailingLabel:
                item.isMissing ? '丢失' : (item.isLink ? '链接' : null),
            onTap: () {
              // 拖拽/放大模式后的松手不当作点击, 防止误复制。
              if (_pressActivatedMode) {
                _pressActivatedMode = false;
                return;
              }
              _handleEmojiTap(item);
            },
            onSecondaryTapUp: (details) =>
                _showItemMenu(item, details.globalPosition),
          ),
        ),
      ),
    );
    return item.isMissing ? Opacity(opacity: 0.4, child: card) : card;
  }

  /// 按下: 记录起点并启动放大预览定时器。
  /// 只有主键 (左键) 参与手势, 右键/中键走各自菜单逻辑。
  void _handleItemPointerDown(EmojiItem item, PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) {
      return;
    }
    _zoomActivationTimer?.cancel();
    _pressStartPosition = event.position;
    _dragActive = false;
    _zoomActive = false;
    _zoomItem = null;
    _dragPath = null;
    _pressActivatedMode = false;
    _zoomActivationTimer = Timer(_zoomActivationDelay, () {
      _zoomActivationTimer = null;
      if (_pressStartPosition == null || _dragActive || !mounted) {
        return;
      }
      setState(() {
        _zoomActive = true;
        _zoomItem = item;
        _pressActivatedMode = true;
      });
    });
  }

  /// 指针进入某张卡片 (MouseTracker 重新命中后触发):
  /// 放大模式 → 切换大图; 拖拽模式 → 与目标卡片实时换位。
  void _handleItemHover(EmojiItem item) {
    if (_zoomActive) {
      if (_zoomItem?.path != item.path) {
        setState(() => _zoomItem = item);
      }
      return;
    }
    if (_dragActive && _dragPath != null && item.path != _dragPath) {
      final category = _controller.selectedCategory;
      if (category != null) {
        _controller.reorderCategoryItem(category, _dragPath!, item.path);
      }
    }
  }

  /// 移动 (仅起始卡片能收到, 因按下时 hit test 锁定):
  /// 超过阈值 → 直接进入拖拽重排并取消放大定时器。
  void _handleItemPointerMove(EmojiItem item, Offset position) {
    if (_pressStartPosition == null || _zoomActive || _dragActive) {
      return;
    }
    final moved = (position - _pressStartPosition!).distance;
    if (moved <= _dragStartSlop) {
      return;
    }
    _zoomActivationTimer?.cancel();
    _zoomActivationTimer = null;
    if (!_controller.canReorderCurrentView || item.isLink || item.isMissing) {
      return;
    }
    setState(() {
      _dragActive = true;
      _dragPath = item.path;
      _pressActivatedMode = true;
    });
  }

  /// 松手/取消: 结束按压状态; 若在拖拽中则把当前顺序持久化。
  void _finishPress() {
    if (_pressStartPosition == null && !_dragActive && !_zoomActive) {
      return;
    }
    final wasDragging = _dragActive;
    _zoomActivationTimer?.cancel();
    _zoomActivationTimer = null;
    _pressStartPosition = null;
    _dragPath = null;
    if (mounted) {
      setState(() {
        _dragActive = false;
        _zoomActive = false;
        _zoomItem = null;
      });
    }
    if (wasDragging) {
      final category = _controller.selectedCategory;
      if (category != null) {
        unawaited(_controller.commitCategoryOrder(category));
      }
    }
  }

  /// 放大预览遮罩: 原始比例接近全窗口显示 + 底部名称胶囊;
  /// IgnorePointer 保证鼠标仍可悬停到其它卡片切换大图。
  Widget _buildZoomOverlay(EmojiItem item) {
    return Container(
      color: Colors.black.withValues(alpha: 0.6),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: item.isMissing
                  ? const Icon(
                      Icons.image_not_supported_outlined,
                      size: 120,
                      color: Colors.white38,
                    )
                  : Image.file(
                      File(item.path),
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                    ),
            ),
          ),
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                item.isLink
                    ? '${item.name}  ·  链接自「${item.homeCategory ?? item.category}」'
                    : item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 拖放悬浮遮罩: 背景模糊 + 深色遮罩 + 胶囊提示文字,
  /// 按当前视图是否可接收显示不同颜色与文案。
  Widget _buildDropOverlay(BuildContext context) {
    final accepted = _controller.canAcceptDroppedImages;
    final color = accepted ? Theme.of(context).colorScheme.primary : Colors.orange;
    return Positioned.fill(
      child: IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            // 模糊底层网格；即使个别显卡驱动下模糊失效，下方深色遮罩仍能保证可读性
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color, width: 2),
              ),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    accepted ? Icons.add_photo_alternate_outlined : Icons.block,
                    size: 44,
                    color: color,
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      accepted
                          ? '松开以添加到当前分类「${_controller.selectedCategory ?? ''}」'
                          : '「最近使用」和「全部」视图不支持拖入添加',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 处理拖放完成: 把拖入的文件/目录导入当前分类, 并用 SnackBar 反馈结果。
  Future<void> _handleImageDrop(DropDoneDetails details) async {
    if (mounted) {
      setState(() => _dragging = false);
    }
    final paths = details.files
        .map((file) => file.path)
        .where((path) => path.isNotEmpty)
        .toList();
    if (paths.isEmpty) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    if (!_controller.canAcceptDroppedImages) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('请先切换到一个具体分类再拖入图片'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final result = await _controller.addImagesToCurrentCategory(paths);
    if (!mounted) {
      return;
    }
    final added = result?.imported.length ?? 0;
    final skipped = result?.skipped ?? 0;
    final deduped = result?.deduped ?? 0;
    final parts = <String>[
      '已添加 $added 张图片',
      if (deduped > 0) '去重链接 $deduped 张',
      if (skipped > 0) '跳过 $skipped 项',
    ];
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          added == 0 && deduped == 0
              ? '拖入的内容中没有可用的图片'
              : '${parts.join('，')}到「${_controller.selectedCategory ?? ''}」',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 未选择表情库根目录时的欢迎引导页。
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

  /// 顶栏: 统计信息 + 搜索框 + 操作按钮 (重扫/置顶/排序/设置);
  /// 窗口较窄 (宽度 < 980) 时改为两行布局以节省横向空间。
  Widget _buildTopBar(BuildContext context) {
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
            children: [
              _buildStatsWrap(),
              const SizedBox(width: 16),
              _buildSearchField(width: 420),
              const Spacer(),
              actions,
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildStatsWrap(),
                const Spacer(),
                actions,
              ],
            ),
            const SizedBox(height: 12),
            _buildSearchField(),
          ],
        );
      },
    );
  }

  /// 顶栏左侧的统计 chips (分类数、表情总数)。
  Widget _buildStatsWrap() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _StatChip(label: '分类', value: '${_controller.categories.length}'),
        _StatChip(label: '总表情', value: '${_controller.totalEmojiCount}'),
      ],
    );
  }

  /// 搜索框: 匹配表情文件名或备注, 有内容时显示清空按钮。
  Widget _buildSearchField({double? width}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: _searchController,
        onChanged: _controller.updateSearchQuery,
        decoration: InputDecoration(
          isDense: true,
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
    );
  }

  /// 分类栏: 横向滚动的分类卡片列表, 前两个固定为"全部"与"最近使用"。
  Widget _buildCategoryBar(BuildContext context) {
    final entries = <_CategoryEntry>[
      _CategoryEntry(
        category: EmojiManagerController.allCategoryView,
        label: '全部',
        imageProvider:
            _categoryImageProvider(_controller.firstItemOverall),
        iconData: Icons.grid_view_outlined,
      ),
      _CategoryEntry(
        category: EmojiManagerController.recentCategoryView,
        label: '最近使用',
        imageProvider:
            _categoryImageProvider(_controller.recentViewThumbnail),
        iconData: Icons.history,
      ),
      for (final category in _controller.categories)
        _CategoryEntry(
          category: category,
          label: category,
          imageProvider:
              _categoryImageProvider(_controller.categoryThumbnails[category]),
        ),
    ];

    // 分类框最外层
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF11161C),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white10),
      ),
      child: SizedBox(
        height: 118,
        child: Scrollbar(
          controller: _categoryScrollController,
          notificationPredicate: (notification) => notification.depth == 0,
          child: Listener(
            onPointerSignal: _handleCategoryPointerSignal,
            child: ListView.separated(
              controller: _categoryScrollController,
              scrollDirection: Axis.horizontal,
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final isSelected =
                    entry.category == _controller.selectedCategory;

                return _CategoryCard(
                  category: entry.label,
                  imageProvider: entry.imageProvider,
                  iconData: entry.iconData,
                  selected: isSelected,
                  onTap: () => _handleCategorySelection(entry.category),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 当前分类为空时显示的占位提示 (区分"无图片"与"无搜索结果")。
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

  /// 热键主键候选列表: A-Z、0-9、F1-F12 的虚拟键码。
  static final List<int> _hotkeyKeyCodeItems = [
    ...List.generate(26, (index) => 0x41 + index), // A-Z
    ...List.generate(10, (index) => 0x30 + index), // 0-9
    ...List.generate(12, (index) => 0x70 + index), // F1-F12
  ];

  /// 把虚拟键码转成可读文本 (字母/数字/F键, 其余显示十六进制)。
  static String _virtualKeyLabel(int keyCode) {
    if (keyCode >= 0x41 && keyCode <= 0x5A) {
      return String.fromCharCode(keyCode);
    }
    if (keyCode >= 0x30 && keyCode <= 0x39) {
      return String.fromCharCode(keyCode);
    }
    if (keyCode >= 0x70 && keyCode <= 0x7B) {
      return 'F${keyCode - 0x6F}';
    }
    return '0x${keyCode.toRadixString(16)}';
  }

  /// 把修饰键掩码 + 主键拼成如 "Ctrl + Shift + V" 的可读文本。
  static String _hotkeyLabel(int modifiers, int keyCode) {
    final parts = <String>[];
    if ((modifiers & WindowControlService.hotkeyModifierControl) != 0) {
      parts.add('Ctrl');
    }
    if ((modifiers & WindowControlService.hotkeyModifierShift) != 0) {
      parts.add('Shift');
    }
    if ((modifiers & WindowControlService.hotkeyModifierAlt) != 0) {
      parts.add('Alt');
    }
    if ((modifiers & WindowControlService.hotkeyModifierWin) != 0) {
      parts.add('Win');
    }
    parts.add(_virtualKeyLabel(keyCode));
    return parts.join(' + ');
  }

  /// 设置面板 (底部弹窗): 目录选择、窗口行为、自动粘贴进程列表、
  /// 全局快捷键、扫描例外与缩略图大小调节。
  Future<void> _showSettingsSheet() async {
    final ignoreDirectoriesController = TextEditingController(
      text: _controller.ignoredDirectories.join(', '),
    );
    final autoPasteController = TextEditingController(
      text: _controller.autoPasteProcesses.join(', '),
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
                          '自动粘贴',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '唤起本窗口时记录前置应用：若其进程名在列表中，点击表情会以位图（CF_DIB，非 PNG/文件）复制，并自动粘贴回该应用窗口。留空表示关闭自动粘贴。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.white54),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: autoPasteController,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            hintText: '例如：QQ.exe, Weixin.exe',
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            await _controller
                                .setAutoPasteProcessesFromText(
                              autoPasteController.text,
                            );
                            if (!context.mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context)
                                .hideCurrentSnackBar();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('已更新自动粘贴应用列表'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.bookmark_added_outlined),
                          label: const Text('保存自动粘贴应用'),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          '全局快捷键',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Switch(
                              value: _controller.hotkeyEnabled,
                              onChanged: (value) =>
                                  _controller.setHotkeyEnabled(value),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${_hotkeyLabel(_controller.hotkeyModifiers, _controller.hotkeyKeyCode)} 显示/隐藏窗口',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final entry in const {
                              'Ctrl': WindowControlService.hotkeyModifierControl,
                              'Shift': WindowControlService.hotkeyModifierShift,
                              'Alt': WindowControlService.hotkeyModifierAlt,
                              'Win': WindowControlService.hotkeyModifierWin,
                            }.entries)
                              FilterChip(
                                label: Text(entry.key),
                                selected: (_controller.hotkeyModifiers &
                                        entry.value) !=
                                    0,
                                onSelected: (selected) {
                                  var modifiers =
                                      _controller.hotkeyModifiers;
                                  modifiers = selected
                                      ? (modifiers | entry.value)
                                      : (modifiers & ~entry.value);
                                  // 全部修饰键都被取消时强制保留 Ctrl, 保证热键有效。
                                  if ((modifiers & 0xF) == 0) {
                                    modifiers |=
                                        WindowControlService
                                            .hotkeyModifierControl;
                                  }
                                  _controller.setHotkeyBinding(
                                    modifiers: modifiers,
                                    keyCode: _controller.hotkeyKeyCode,
                                  );
                                },
                              ),
                            const SizedBox(width: 4),
                            DropdownButton<int>(
                              value: _hotkeyKeyCodeItems
                                      .contains(_controller.hotkeyKeyCode)
                                  ? _controller.hotkeyKeyCode
                                  : 0x56,
                              items: [
                                for (final keyCode in _hotkeyKeyCodeItems)
                                  DropdownMenuItem<int>(
                                    value: keyCode,
                                    child: Text(_virtualKeyLabel(keyCode)),
                                  ),
                              ],
                              onChanged: (value) {
                                if (value == null) {
                                  return;
                                }
                                _controller.setHotkeyBinding(
                                  modifiers: _controller.hotkeyModifiers,
                                  keyCode: value,
                                );
                              },
                            ),
                          ],
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
      autoPasteController.dispose();
    }
  }

  /// Ctrl + 鼠标滚轮: 实时调节网格缩略图大小。
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

  /// 鼠标滚轮横向滚动分类栏 (分类栏为横向 ListView)。
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

  /// 点击表情:
  /// 1. 若唤起前的前台应用在自动粘贴列表中, 以位图/文件复制并自动粘贴回该应用;
  /// 2. 否则退化为把文件复制到剪贴板;
  /// 两条路径均会记录使用次数。
  Future<void> _handleEmojiTap(EmojiItem item) async {
    if (Platform.isWindows && _controller.autoPasteProcesses.isNotEmpty) {
      final processName = await WindowControlService
          .getPreviousForegroundProcessName();
      if (processName != null &&
          _controller.matchesAutoPasteTarget(processName)) {
        final handled =
            await PlatformEmojiClipboardService.copyImageAndPaste(item.path);
        if (!mounted) {
          return;
        }
        if (handled) {
          unawaited(_controller.recordUsage(item.path));
          return;
        }
      }
    }

    final copied = await PlatformEmojiClipboardService.copyFile(item.path);
    if (!mounted) {
      return;
    }

    if (copied) {
      unawaited(_controller.recordUsage(item.path));
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

  /// 右键菜单: 复制到剪贴板 / 预览与备注 / 添加到分类 / 从分类移除 /
  /// 刷新缩略图 / 在资源管理器中显示 (仅 Windows) / 删除或移除失效链接。
  Future<void> _showItemMenu(EmojiItem item, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'copy',
          child: ListTile(
            leading: Icon(Icons.content_copy),
            title: Text('复制到剪贴板'),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'preview',
          child: ListTile(
            leading: Icon(Icons.visibility_outlined),
            title: Text('预览与备注'),
          ),
        ),
        if (!item.isMissing)
          const PopupMenuItem<String>(
            value: 'addToCategory',
            child: ListTile(
              leading: Icon(Icons.playlist_add),
              title: Text('添加到分类…'),
            ),
          ),
        if (item.isLink && !item.isMissing)
          const PopupMenuItem<String>(
            value: 'removeLink',
            child: ListTile(
              leading: Icon(Icons.link_off),
              title: Text('从分类移除'),
            ),
          ),
        if (item.isMissing)
          const PopupMenuItem<String>(
            value: 'removeMissingLink',
            child: ListTile(
              leading: Icon(Icons.link_off, color: Colors.orangeAccent),
              title: Text('移除失效链接',
                  style: TextStyle(color: Colors.orangeAccent)),
            ),
          ),
        const PopupMenuItem<String>(
          value: 'refresh',
          child: ListTile(
            leading: Icon(Icons.image_outlined),
            title: Text('刷新缩略图'),
          ),
        ),
        if (Platform.isWindows)
          const PopupMenuItem<String>(
            value: 'reveal',
            child: ListTile(
              leading: Icon(Icons.folder_open_outlined),
              title: Text('在资源管理器中显示'),
            ),
          ),
        if (!item.isLink)
          const PopupMenuItem<String>(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.redAccent),
              title: Text('删除这张图片',
                  style: TextStyle(color: Colors.redAccent)),
            ),
          ),
      ],
    );
    if (!mounted || selected == null) {
      return;
    }
    switch (selected) {
      case 'copy':
        await _handleEmojiTap(item);
      case 'preview':
        await _showPreview(item);
      case 'addToCategory':
        await _showAddToCategoryDialog(item);
      case 'removeLink':
        await _removeLinkFromCategory(item);
      case 'removeMissingLink':
        await _removeMissingLinkItem(item);
      case 'refresh':
        await _refreshItemThumbnail(item);
      case 'reveal':
        _revealInExplorer(item);
      case 'delete':
        await _handleDeleteItem(item);
    }
  }

  /// "添加到分类…" 多选对话框: 把这张图同时加入若干其他分类 (建立链接)。
  Future<void> _showAddToCategoryDialog(EmojiItem item) async {
    final homeCategory = item.homeCategory ?? item.category;
    final candidates = _controller.categories
        .where((category) => category != homeCategory)
        .toList();
    if (candidates.isEmpty) {
      return;
    }

    // 已经包含这张图的分类默认勾选 (链接已存在)。
    final selected = <String>{
      for (final category in candidates)
        if (_controller.categoryContains(category, item.path)) category,
    };

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('把「${item.name}」添加到分类'),
          content: SizedBox(
            width: 280,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final category in candidates)
                  CheckboxListTile(
                    dense: true,
                    title: Text(category),
                    value: selected.contains(category),
                    onChanged: (checked) {
                      setDialogState(() {
                        checked == true
                            ? selected.add(category)
                            : selected.remove(category);
                      });
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.of(dialogContext).pop(true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    var added = 0;
    for (final category in selected) {
      final ok = await _controller.addImageToCategory(
        itemPath: item.path,
        category: category,
      );
      if (ok) {
        added += 1;
      }
    }
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(added > 0 ? '已添加到 $added 个分类' : '未添加（可能已存在于所选分类）'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 把链接项从其所在的链接分类中移除 (不动实体文件)。
  Future<void> _removeLinkFromCategory(EmojiItem item) async {
    final removed = await _controller.removeImageLink(item.path);
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(removed ? '已从「${item.category}」移除（文件保留）' : '移除失败'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 移除一条已置灰的失效链接记录。
  Future<void> _removeMissingLinkItem(EmojiItem item) async {
    final removed = await _controller.removeMissingLink(item.path);
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(removed ? '已移除失效链接记录' : '移除失败'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 删除图片 (带确认弹窗), 删除后用 SnackBar 反馈结果。
  Future<void> _handleDeleteItem(EmojiItem item) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除图片'),
        content: Text(
          '确定要删除「${item.name}」吗？\n磁盘上的图片文件会被一并删除，无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    final deleted = await _controller.deleteItem(item.path);
    if (!mounted) {
      return;
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          deleted ? '已删除 ${item.name}' : '删除失败：文件不存在或无法删除',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 在资源管理器中定位显示图片文件 (仅 Windows)。
  Future<void> _revealInExplorer(EmojiItem item) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!File(item.path).existsSync()) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('文件已不存在'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final revealed =
        await PlatformEmojiClipboardService.revealInExplorer(item.path);
    if (revealed || !mounted) {
      return;
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(
        content: Text('无法打开资源管理器'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// 强制重新生成单张图片的缩略图。
  Future<void> _refreshItemThumbnail(EmojiItem item) async {
    // GIF 预览直接加载源文件, 其修改时间可能没变, 需主动逐出缓存;
    // 缩略图文件重建后修改时间会更新, FileImage 缓存键随之变化, 无需处理。
    PaintingBinding.instance.imageCache.evict(FileImage(File(item.path)));

    final refreshed = await _controller.refreshThumbnail(item.path);
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          refreshed ? '已刷新缩略图' : '刷新失败：无法重新生成缩略图',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 网格卡片的图片 provider: 优先用缩略图 (按网格尺寸解码);
  /// GIF 无缩略图, 直接加载源文件以显示动图。
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

  /// 分类卡片的图片 provider: 使用分类封面缩略图 (96px 逻辑尺寸解码)。
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

  /// 取可用的缩略图路径 (文件必须存在, 否则视为无缩略图)。
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

  /// 切换分类: 清空图片缓存后通知 Controller (防止跨分类的缓存图片闪现)。
  void _handleCategorySelection(String category) {
    if (_controller.selectedCategory == category) {
      return;
    }
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
    _controller.selectCategory(category);
  }

  /// 打开表情预览弹窗, 注入备注保存与排序回调。
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

/// 链接自愈/丢失悬浮提示: 8 秒后自动消失, 可手动关闭。
class _HealReportBanner extends StatefulWidget {
  const _HealReportBanner({
    required this.report,
    required this.onDismiss,
  });

  final LinkHealReport report;
  final VoidCallback onDismiss;

  @override
  State<_HealReportBanner> createState() => _HealReportBannerState();
}

class _HealReportBannerState extends State<_HealReportBanner> {
  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();
    _autoDismissTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) {
        widget.onDismiss();
      }
    });
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final lines = <String>[
      for (final heal in report.healed)
        '已自动恢复: ${heal.key} → ${heal.value}',
      for (final path in report.missing) '无法恢复: $path',
    ];

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xEE23282E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              report.missing.isEmpty
                  ? Icons.verified_outlined
                  : Icons.warning_amber_outlined,
              color: report.missing.isEmpty
                  ? Colors.lightGreenAccent
                  : Colors.orangeAccent,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    report.missing.isEmpty
                        ? '检测到 ${report.healed.length} 个失效链接，已全部自动恢复'
                        : '检测到失效链接：恢复 ${report.healed.length} 个，'
                            '无法恢复 ${report.missing.length} 个',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final line in lines)
                    Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: widget.onDismiss,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 16, color: Colors.white54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶栏统计 chip (标签 + 数值)。
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

/// 分类栏卡片的数据描述 (分类标识、显示名、封面图、可选图标)。
class _CategoryEntry {
  const _CategoryEntry({
    required this.category,
    required this.label,
    required this.imageProvider,
    this.iconData,
  });

  final String category;
  final String label;
  final ImageProvider<Object>? imageProvider;
  final IconData? iconData;
}

/// 单个分类卡片: 封面图 (Cover 裁切) + 分类名, 选中时高亮描边。
class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.category,
    required this.imageProvider,
    required this.selected,
    required this.onTap,
    this.iconData,
  });

  final String category;
  final ImageProvider<Object>? imageProvider;
  final IconData? iconData;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholderIcon = iconData ?? Icons.folder_copy_outlined;

    return Material(
      color: Colors.transparent,
      // 分类框鼠标悬浮时高亮部分
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Ink(
          width: 100,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1D21),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : Colors.white12,
              width: selected ? 1.6 : 1,
            ),
          ),
          // 分类图片最内框
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox.expand(
                      child: imageProvider == null
                          ? ColoredBox(
                              color: const Color(0xFF30343A),
                              child: Icon(
                                placeholderIcon,
                                color: Colors.white38,
                                size: 32,
                              ),
                            )
                          : Image(
                              image: imageProvider!,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return ColoredBox(
                                  color: const Color(0xFF30343A),
                                  child: Icon(
                                    placeholderIcon,
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
