import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/emoji_item.dart';
import '../models/emoji_scan_result.dart';
import '../models/sort_order.dart';
import 'emoji_library_index.dart';
import 'emoji_log_service.dart';
import 'emoji_thumbnail_service.dart';

/// 导入结果: 成功导入的表情列表、被跳过的数量 (非图片或读取失败)
/// 与去重命中数量 (已有同内容图片, 只建立链接不复制)。
class ImportResult {
  const ImportResult({
    required this.imported,
    required this.skipped,
    this.deduped = 0,
  });

  final List<EmojiItem> imported;
  final int skipped;
  final int deduped;
}

/// 表情库的磁盘数据访问层。
///
/// 目录约定: [rootPath] 为表情库根目录, 根目录下每个子目录是一个分类,
/// 根目录直属的图片属于"未分类"。每个分类目录内可包含:
/// - `emoji_image_order.json`: 手动排序文件
/// - `emoji_remarks.json`: 图片备注表 (文件名 -> 备注)
/// - `.emoji_manager/`: 缩略图缓存与索引 (由 [EmojiThumbnailService] 管理)
///
/// 一图多分类: 文件实体始终在 home 分类目录中; 中央索引 `library.json`
/// (由 [EmojiLibraryIndex] 管理) 记录额外的分类链接, 扫描时应用到结果中。
class EmojiRepository {
  EmojiRepository({
    EmojiThumbnailService? thumbnailService,
  }) : _thumbnailService = thumbnailService ?? EmojiThumbnailService();

  /// 根目录直属图片归属的虚拟分类名。
  static const uncategorized = '未分类';

  /// 始终忽略的目录名 (同步工具目录、日志目录等)。
  static const defaultIgnoredDirectories = <String>{'.sync', 'logs'};
  static const _orderFileName = 'emoji_image_order.json';
  static const _remarksFileName = 'emoji_remarks.json';
  static const _imageExtensions = <String>{
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  };

  final EmojiThumbnailService _thumbnailService;
  final EmojiLibraryIndex _libraryIndex = EmojiLibraryIndex();

  /// size 预筛索引: 字节数 -> 相对路径集合 (扫描时构建, 去重/自愈共用)。
  final Map<int, Set<String>> _sizeIndex = {};
  /// 文件名索引: 文件名 (含扩展名) -> 相对路径集合 (自愈候选线索)。
  final Map<String, Set<String>> _nameIndex = {};
  /// 相对路径 -> 已知哈希 (会话内缓存, 来源: 注册表反查 + 本次会话计算)。
  final Map<String, String> _hashByPath = {};

  /// 扫描整个表情库, 返回分类 -> 表情列表 及分类元数据。
  ///
  /// 同时完成五件事:
  /// 1. 递归收集每个分类下的图片并组装 [EmojiItem];
  /// 2. 确保缩略图存在 (必要时在后台 isolate 生成);
  /// 3. 以本次扫描到的源图集合清理缩略图索引中的过期条目;
  /// 4. 构建 size/文件名索引供去重与自愈使用;
  /// 5. 对账中央索引: 应用分类链接, 失效链接先自愈 (按 size+哈希找回),
  ///    找不回的置灰保留并写入报告。
  Future<EmojiScanResult> scanWithMetadata(
    String rootPath, {
    Set<String> ignoredDirectoryNames = const {},
  }) async {
    final root = Directory(rootPath);
    if (!root.existsSync()) {
      return EmojiScanResult.empty();
    }

    final effectiveIgnored = _buildIgnoredDirectories(ignoredDirectoryNames);
    final thumbnailIndex = await _thumbnailService.loadIndex(rootPath);
    final activeSourcePaths = <String>{};
    final remarksByPath = await loadAllRemarks(
      rootPath,
      ignoredDirectoryNames: ignoredDirectoryNames,
    );
    await _libraryIndex.load(rootPath);
    _rebuildHashByPath();

    final itemsByCategory = <String, List<EmojiItem>>{};
    final metadata = <String, CategoryMetadata>{};
    metadata[uncategorized] = CategoryMetadata(
      name: uncategorized,
      path: root.path,
      lastModified: root.statSync().modified.millisecondsSinceEpoch,
    );

    final uncategorizedItems = <EmojiItem>[];
    final children = root.listSync().toList()
      ..sort(
        (left, right) => p
            .basename(left.path)
            .toLowerCase()
            .compareTo(p.basename(right.path).toLowerCase()),
      );

    for (final child in children) {
      if (child is Directory) {
        final name = p.basename(child.path);
        if (effectiveIgnored.contains(name)) {
          continue;
        }
        metadata[name] = CategoryMetadata(
          name: name,
          path: child.path,
          lastModified: child.statSync().modified.millisecondsSinceEpoch,
        );
        final categoryItems = <EmojiItem>[];
        await _collectImagesRecursively(
          child,
          name,
          categoryItems,
          remarksByPath,
          rootPath: rootPath,
          thumbnailIndex: thumbnailIndex,
          activeSourcePaths: activeSourcePaths,
          ignoredDirectoryNames: effectiveIgnored,
        );
        if (categoryItems.isNotEmpty) {
          itemsByCategory[name] = categoryItems;
        }
      } else if (child is File && _isImageFile(child.path)) {
        final item = await _toEmojiItem(
          child,
          uncategorized,
          rootPath: rootPath,
          thumbnailIndex: thumbnailIndex,
          activeSourcePaths: activeSourcePaths,
          remark: remarksByPath[child.path],
        );
        uncategorizedItems.add(item);
      }
    }

    if (uncategorizedItems.isNotEmpty) {
      itemsByCategory[uncategorized] = uncategorizedItems;
    }

    // 对账中央索引: 应用分类链接 + 自愈失效链接。
    final healReport = LinkHealReport();
    await _applyLinks(
      rootPath: rootPath,
      itemsByCategory: itemsByCategory,
      metadata: metadata,
      remarksByPath: remarksByPath,
      thumbnailIndex: thumbnailIndex,
      activeSourcePaths: activeSourcePaths,
      healReport: healReport,
    );

    await _thumbnailService.saveIndex(
      rootPath: rootPath,
      index: thumbnailIndex,
      activeSourcePaths: activeSourcePaths,
    );

    EmojiLogService.instance.info(
      '扫描完成: ${metadata.length} 个分类, '
      '${itemsByCategory.values.fold<int>(0, (sum, items) => sum + items.length)} 张图',
    );

    return EmojiScanResult(
      itemsByCategory: itemsByCategory,
      categoryMetadata: metadata,
    )..healReport = healReport;
  }

  /// 把索引中的分类链接应用到扫描结果; 失效链接先自愈再应用,
  /// 找不回的以置灰占位项呈现 (isMissing), 并记录报告与日志。
  Future<void> _applyLinks({
    required String rootPath,
    required Map<String, List<EmojiItem>> itemsByCategory,
    required Map<String, CategoryMetadata> metadata,
    required Map<String, String> remarksByPath,
    required Map<String, ThumbnailEntry> thumbnailIndex,
    required Set<String> activeSourcePaths,
    required LinkHealReport healReport,
  }) async {
    if (_libraryIndex.links.isEmpty) {
      return;
    }

    var indexDirty = false;
    final links = _libraryIndex.links.values.toList(growable: false);
    for (final link in links) {
      var file = File(p.join(rootPath, link.path));
      if (!file.existsSync()) {
        final healedPath = await _selfHealLink(rootPath, link, healReport);
        if (healedPath != null) {
          indexDirty = true;
          file = File(p.join(rootPath, healedPath));
        } else {
          if (!link.missing) {
            link.missing = true;
            indexDirty = true;
          }
          healReport.missing.add(link.path);
          EmojiLogService.instance
              .warn('无法恢复的链接: "${link.path}" (无可匹配候选)');
          for (final category in link.categories) {
            if (!metadata.containsKey(category)) {
              continue;
            }
            itemsByCategory.putIfAbsent(category, () => []).add(
                  _buildMissingLinkItem(link, category, rootPath: rootPath),
                );
          }
          continue;
        }
      } else if (link.missing) {
        link.missing = false;
        indexDirty = true;
        EmojiLogService.instance.info('置灰链接已恢复: "${link.path}"');
      }

      final homeCategory = homeCategoryOf(rootPath, file.path);
      for (final category in link.categories) {
        if (!metadata.containsKey(category)) {
          EmojiLogService.instance.warn(
            '链接目标分类不存在, 跳过: "${link.path}" -> "$category"',
          );
          continue;
        }
        final item = await _toEmojiItem(
          file,
          category,
          rootPath: rootPath,
          thumbnailIndex: thumbnailIndex,
          activeSourcePaths: activeSourcePaths,
          remark: remarksByPath[file.path],
          isLink: true,
          homeCategory: homeCategory,
        );
        itemsByCategory.putIfAbsent(category, () => []).add(item);
      }
    }

    if (indexDirty) {
      await _libraryIndex.save(rootPath);
    }
  }

  /// 尝试自愈一条失效链接: 按 size + 文件名筛候选, 哈希验证命中后更新路径。
  /// 成功返回新的相对路径, 失败返回 null。
  Future<String?> _selfHealLink(
    String rootPath,
    LibraryLink link,
    LinkHealReport healReport,
  ) async {
    EmojiLogService.instance
        .warn('链接失效: "${link.path}" (size=${link.size}) -> 尝试自愈');
    final oldName = p.basename(link.path);
    final oldDir = p.dirname(link.path);
    final candidates = <String>{
      ..._sizeIndex[link.size] ?? const <String>{},
      ..._nameIndex[oldName] ?? const <String>{},
    }..remove(link.path);

    int score(String candidate) {
      var value = 0;
      if (p.dirname(candidate) == oldDir) {
        value -= 4;
      }
      if (p.basename(candidate) == oldName) {
        value -= 2;
      }
      return value;
    }

    final ranked = candidates.toList()
      ..sort((left, right) {
        final byScore = score(left).compareTo(score(right));
        if (byScore != 0) {
          return byScore;
        }
        return left.length.compareTo(right.length);
      });

    for (final candidate in ranked) {
      final candidateFile = File(p.join(rootPath, candidate));
      final candidateHash =
          _hashByPath[candidate] ?? await computeFileSha256(candidateFile);
      if (candidateHash == null) {
        continue;
      }
      _hashByPath[candidate] = candidateHash;
      if (candidateHash == link.hash) {
        _libraryIndex.updateLinkPath(link.path, candidate);
        healReport.healed.add(MapEntry(link.path, candidate));
        EmojiLogService.instance
            .info('自愈成功: "${link.path}" -> "$candidate" (hash 匹配)');
        return candidate;
      }
    }
    return null;
  }

  /// 构造失效链接的置灰占位项 (文件已不在磁盘上)。
  EmojiItem _buildMissingLinkItem(
    LibraryLink link,
    String category, {
    required String rootPath,
  }) {
    final extension = p.extension(link.path).toLowerCase();
    return EmojiItem(
      path: p.join(rootPath, link.path),
      name: p.basename(link.path),
      mimeType: _mimeTypeForExtension(extension),
      category: category,
      lastModified: 0,
      fileSize: link.size,
      isLink: true,
      isMissing: true,
    );
  }

  /// 对所有分类统一应用 [sortOrder] 排序。
  Future<Map<String, List<EmojiItem>>> sortItemsByCategory(
    String rootPath,
    Map<String, List<EmojiItem>> itemsByCategory,
    SortOrder sortOrder,
  ) async {
    final result = <String, List<EmojiItem>>{};
    for (final entry in itemsByCategory.entries) {
      result[entry.key] = await sortCategoryItems(
        rootPath: rootPath,
        category: entry.key,
        items: entry.value,
        sortOrder: sortOrder,
      );
    }
    return result;
  }

  /// 对单个分类的表情列表排序。
  ///
  /// - byName: 忽略大小写按名称升序;
  /// - byTime: 按修改时间倒序 (最新在前);
  /// - byOrder: 读取分类的顺序文件, 未登记的图片排在末尾并按名称兜底。
  ///
  /// 链接项不参与排序规则, 始终按加入顺序排在原生项之后。
  Future<List<EmojiItem>> sortCategoryItems({
    required String rootPath,
    required String category,
    required List<EmojiItem> items,
    required SortOrder sortOrder,
  }) async {
    if (items.isEmpty) {
      return items;
    }

    final nativeItems = items.where((item) => !item.isLink).toList();
    final linkItems = items.where((item) => item.isLink).toList();
    if (nativeItems.isEmpty) {
      return items;
    }

    final List<EmojiItem> sortedNative;
    switch (sortOrder) {
      case SortOrder.byName:
        sortedNative = nativeItems
          ..sort(
            (left, right) => left.name.toLowerCase().compareTo(right.name.toLowerCase()),
          );
        break;
      case SortOrder.byTime:
        sortedNative = nativeItems
          ..sort((left, right) => right.lastModified.compareTo(left.lastModified));
        break;
      case SortOrder.byOrder:
        final order = await readOrderForCategory(rootPath, category);
        if (order.isEmpty) {
          sortedNative = nativeItems
            ..sort(
              (left, right) =>
                  left.name.toLowerCase().compareTo(right.name.toLowerCase()),
            );
          break;
        }

        final orderIndex = <String, int>{
          for (var index = 0; index < order.length; index++) order[index]: index,
        };
        sortedNative = nativeItems
          ..sort((left, right) {
            final leftIndex = orderIndex[left.name] ?? 1 << 30;
            final rightIndex = orderIndex[right.name] ?? 1 << 30;
            if (leftIndex != rightIndex) {
              return leftIndex.compareTo(rightIndex);
            }
            return left.name.toLowerCase().compareTo(right.name.toLowerCase());
          });
        break;
    }
    return [...sortedNative, ...linkItems];
  }

  /// 读取分类的顺序文件 (`emoji_image_order.json`), 返回图片名列表。
  /// 文件缺失或内容非法时返回空列表。
  Future<List<String>> readOrderForCategory(String rootPath, String category) async {
    final categoryDirectory = _resolveCategoryDirectory(rootPath, category);
    final file = File(p.join(categoryDirectory.path, _orderFileName));
    if (!file.existsSync()) {
      return const [];
    }

    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) {
        return const [];
      }

      final images = json['images'];
      if (images is! List<dynamic>) {
        return const [];
      }

      return images.whereType<String>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// 把当前列表顺序写回分类的顺序文件 (拖拽排序后调用)。
  Future<void> saveOrderForCategory({
    required String rootPath,
    required String category,
    required List<EmojiItem> items,
  }) async {
    final categoryDirectory = _resolveCategoryDirectory(rootPath, category);
    await categoryDirectory.create(recursive: true);
    final file = File(p.join(categoryDirectory.path, _orderFileName));
    final payload = <String, dynamic>{
      'images': items.map((item) => item.name).toList(),
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
  }

  /// 递归加载所有分类目录的备注, 返回 图片绝对路径 -> 备注。
  Future<Map<String, String>> loadAllRemarks(
    String rootPath, {
    Set<String> ignoredDirectoryNames = const {},
  }) async {
    final result = <String, String>{};
    final root = Directory(rootPath);
    if (!root.existsSync()) {
      return result;
    }

    await _loadFolderRemarksRecursive(
      root,
      result,
      ignoredDirectoryNames: _buildIgnoredDirectories(ignoredDirectoryNames),
    );
    return result;
  }

  /// 保存/清空单张图片的备注 (写入图片所在目录的备注文件;
  /// 备注为空白则移除条目, 表空时删除文件)。
  Future<void> saveImageRemark({
    required String imagePath,
    required String remark,
  }) async {
    final imageFile = File(imagePath);
    final folder = imageFile.parent;
    await folder.create(recursive: true);
    final remarksFile = File(p.join(folder.path, _remarksFileName));
    final remarks = await _loadRemarksForFolder(folder);
    final normalizedRemark = remark.trim();
    if (normalizedRemark.isEmpty) {
      remarks.remove(imageFile.uri.pathSegments.last);
    } else {
      remarks[imageFile.uri.pathSegments.last] = normalizedRemark;
    }

    if (remarks.isEmpty) {
      if (remarksFile.existsSync()) {
        await remarksFile.delete();
      }
      return;
    }

    await remarksFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(remarks),
    );
  }

  /// 把一张已有图片加入其他分类 (建立索引链接, 不复制文件)。
  /// 返回新分类下的链接项; 已在该分类 / 文件缺失 / 哈希失败时返回 null。
  Future<EmojiItem?> addImageToCategory({
    required String rootPath,
    required EmojiItem item,
    required String category,
  }) async {
    final homeCategory = item.homeCategory ?? item.category;
    if (category == homeCategory) {
      return null;
    }
    final file = File(item.path);
    if (!file.existsSync()) {
      return null;
    }

    final relativePath = p.relative(item.path, from: rootPath);
    final size = item.fileSize > 0 ? item.fileSize : file.statSync().size;
    var hash = _hashByPath[relativePath];
    hash ??= await computeFileSha256(file);
    if (hash == null) {
      return null;
    }
    _registerHash(hash, relativePath);

    if (!_libraryIndex.addLink(
      relativePath: relativePath,
      category: category,
      hash: hash,
      size: size,
    )) {
      return null;
    }
    await _libraryIndex.save(rootPath);
    EmojiLogService.instance.info('添加链接: "$relativePath" -> 分类 "$category"');

    return item.copyWith(
      category: category,
      isLink: true,
      isMissing: false,
      homeCategory: homeCategory,
    );
  }

  /// 把图片从链接分类 [category] 中移除 (只删索引链接, 不动文件)。
  Future<bool> removeImageLinkFromCategory({
    required String rootPath,
    required EmojiItem item,
    required String category,
  }) async {
    final relativePath = p.relative(item.path, from: rootPath);
    final removed = _libraryIndex.removeLinkFromCategory(
      relativePath: relativePath,
      category: category,
    );
    if (removed) {
      await _libraryIndex.save(rootPath);
      EmojiLogService.instance
          .info('移除链接: "$relativePath" 从分类 "$category"');
    }
    return removed;
  }

  /// 移除一条已置灰的失效链接记录。
  Future<bool> removeMissingLink({
    required String rootPath,
    required EmojiItem item,
  }) async {
    final relativePath = p.relative(item.path, from: rootPath);
    final link = _libraryIndex.links[relativePath];
    if (link == null || !link.missing) {
      return false;
    }
    _libraryIndex.removeLink(relativePath);
    await _libraryIndex.save(rootPath);
    EmojiLogService.instance.info('移除失效链接记录: "$relativePath"');
    return true;
  }

  /// 删除图片文件, 并同步清理其备注条目、顺序文件条目、缩略图缓存
  /// 与指向它的所有索引链接。文件不存在或删除失败时返回 false。
  Future<bool> deleteImage({
    required String rootPath,
    required String category,
    required EmojiItem item,
  }) async {
    final imageFile = File(item.path);
    if (!imageFile.existsSync()) {
      return false;
    }
    final relativePath = p.relative(item.path, from: rootPath);

    // 1. 从所在目录的备注文件中移除备注条目。
    final folder = imageFile.parent;
    final remarksFile = File(p.join(folder.path, _remarksFileName));
    if (remarksFile.existsSync()) {
      final remarks = await _loadRemarksForFolder(folder);
      remarks.remove(imageFile.uri.pathSegments.last);
      if (remarks.isEmpty) {
        await remarksFile.delete();
      } else {
        await remarksFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(remarks),
        );
      }
    }

    // 2. 从分类顺序文件中移除条目。
    final orderFile = File(
      p.join(_resolveCategoryDirectory(rootPath, category).path, _orderFileName),
    );
    if (orderFile.existsSync()) {
      final order = await readOrderForCategory(rootPath, category);
      final remaining = order.where((name) => name != item.name).toList();
      if (remaining.length != order.length) {
        if (remaining.isEmpty) {
          await orderFile.delete();
        } else {
          await orderFile.writeAsString(
            const JsonEncoder.withIndent('  ')
                .convert(<String, dynamic>{'images': remaining}),
          );
        }
      }
    }

    // 3. 删除缩略图缓存及其索引条目。
    final thumbnailIndex = await _thumbnailService.loadIndex(rootPath);
    await _thumbnailService.invalidate(
      rootPath: rootPath,
      filePath: item.path,
      index: thumbnailIndex,
    );
    await _thumbnailService.saveIndex(
      rootPath: rootPath,
      index: thumbnailIndex,
      activeSourcePaths: thumbnailIndex.keys.toSet(),
    );

    // 4. 清理中央索引: 指向该文件的所有链接与哈希登记。
    _libraryIndex.removeLink(relativePath);
    _libraryIndex.forgetHashByPath(relativePath);
    _hashByPath.remove(relativePath);
    _sizeIndex[item.fileSize]?.remove(relativePath);
    await _libraryIndex.save(rootPath);
    EmojiLogService.instance.info('删除图片并清理索引链接: "$relativePath"');

    // 5. 删除图片文件本身。
    await imageFile.delete();
    return true;
  }

  /// 递归收集 [directory] 下 (含子目录) 的图片文件并组装为 [EmojiItem]。
  Future<void> _collectImagesRecursively(
    Directory directory,
    String category,
    List<EmojiItem> collector,
    Map<String, String> remarksByPath,
    {
    required String rootPath,
    required Map<String, ThumbnailEntry> thumbnailIndex,
    required Set<String> activeSourcePaths,
    required Set<String> ignoredDirectoryNames,
  }) async {
    final children = directory.listSync().toList()
      ..sort(
        (left, right) => p
            .basename(left.path)
            .toLowerCase()
            .compareTo(p.basename(right.path).toLowerCase()),
      );

    for (final child in children) {
      if (child is Directory) {
        final name = p.basename(child.path);
        if (ignoredDirectoryNames.contains(name)) {
          continue;
        }
        await _collectImagesRecursively(
          child,
          category,
          collector,
          remarksByPath,
          rootPath: rootPath,
          thumbnailIndex: thumbnailIndex,
          activeSourcePaths: activeSourcePaths,
          ignoredDirectoryNames: ignoredDirectoryNames,
        );
      } else if (child is File && _isImageFile(child.path)) {
        collector.add(
          await _toEmojiItem(
            child,
            category,
            rootPath: rootPath,
            thumbnailIndex: thumbnailIndex,
            activeSourcePaths: activeSourcePaths,
            remark: remarksByPath[child.path],
          ),
        );
      }
    }
  }

  /// 按扩展名过滤图片文件 (仅用于扫描已有文件; 新导入一律走魔数检测)。
  bool _isImageFile(String filePath) {
    return _imageExtensions.contains(p.extension(filePath).toLowerCase());
  }

  /// 把拖入的文件/目录导入到 [category] 对应的目录。
  /// 目录会递归展开; 非图片文件被跳过;
  /// 与库中已有内容相同的图片不复制, 只建立分类链接 (去重)。
  Future<ImportResult> importDroppedPaths({
    required String rootPath,
    required String category,
    required List<String> paths,
  }) async {
    final imagePaths = <String>[];
    for (final path in paths) {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        imagePaths.addAll(_collectImagePathsInDirectory(Directory(path)));
      } else if (type == FileSystemEntityType.file) {
        imagePaths.add(path);
      }
    }

    final imported = <EmojiItem>[];
    var skipped = 0;
    var deduped = 0;
    for (final path in imagePaths) {
      final item = await _importImageToCategory(
        rootPath: rootPath,
        category: category,
        sourcePath: path,
      );
      if (item == null) {
        skipped += 1;
      } else {
        if (item.isLink) {
          deduped += 1;
        }
        imported.add(item);
      }
    }
    return ImportResult(imported: imported, skipped: skipped, deduped: deduped);
  }

  /// 递归收集目录下的图片路径, 跳过隐藏目录 (如 .sync / 缓存目录)。
  List<String> _collectImagePathsInDirectory(Directory directory) {
    final result = <String>[];
    for (final child in directory.listSync()) {
      final name = p.basename(child.path);
      if (child is Directory) {
        // 跳过隐藏目录 (.sync / 缓存目录等)。
        if (name.startsWith('.')) {
          continue;
        }
        result.addAll(_collectImagePathsInDirectory(child));
      } else if (child is File && _isImageFile(child.path)) {
        result.add(child.path);
      }
    }
    return result;
  }

  /// 把一张拖入的图片复制进 [category] 目录并返回生成的 [EmojiItem]。
  ///
  /// 真实格式从文件头嗅探得出, 因为拖拽来源 (如 QQ) 给出的临时文件
  /// 扩展名经常与内容不符。若源文件本就在目标目录中, 则原地复用、
  /// 保留原文件名 (目录扫描依赖扩展名, 需保持一致)。
  ///
  /// 去重: 导入前流式计算源文件 SHA-256, 先按注册表快速命中,
  /// 再按 size 预筛候选并哈希精验; 命中时不复制, 只为已有文件建立
  /// 指向当前分类的索引链接。
  /// 源文件缺失或不是受支持的图片时返回 null。
  Future<EmojiItem?> _importImageToCategory({
    required String rootPath,
    required String category,
    required String sourcePath,
  }) async {
    final sourceFile = File(sourcePath);
    if (!sourceFile.existsSync()) {
      return null;
    }
    final detectedExtension = await _detectImageFormat(sourceFile);
    if (detectedExtension == null) {
      return null;
    }

    final categoryDirectory = _resolveCategoryDirectory(rootPath, category);
    await categoryDirectory.create(recursive: true);

    // 原地复用: 保留磁盘上的原文件名, 与目录扫描器的扩展名约定保持一致。
    if (_isInsideDirectory(sourcePath, categoryDirectory.path)) {
      return _importInPlace(
        sourceFile: sourceFile,
        category: category,
        rootPath: rootPath,
      );
    }

    // 去重: 内容相同的图已存在时不复制, 改为建立链接。
    final sourceSize = sourceFile.statSync().size;
    final sourceHash = await computeFileSha256(sourceFile);
    if (sourceHash != null) {
      final duplicate = await _findDuplicateRelativePath(
        rootPath: rootPath,
        hash: sourceHash,
        size: sourceSize,
      );
      if (duplicate != null) {
        final duplicateFile = File(p.join(rootPath, duplicate));
        final homeCategory = homeCategoryOf(rootPath, duplicateFile.path);
        if (homeCategory == category) {
          // 已存在于目标分类, 无需处理, 返回现有条目。
          final thumbnailIndex = await _thumbnailService.loadIndex(rootPath);
          return _toEmojiItem(
            duplicateFile,
            category,
            rootPath: rootPath,
            thumbnailIndex: thumbnailIndex,
            activeSourcePaths: {duplicate},
            remark: null,
          );
        }
        if (_libraryIndex.addLink(
          relativePath: duplicate,
          category: category,
          hash: sourceHash,
          size: sourceSize,
        )) {
          await _libraryIndex.save(rootPath);
          EmojiLogService.instance.info(
            '去重命中: "$duplicate" 已存在, 建立链接到分类 "$category" (hash=${sourceHash.substring(0, 12)}...)',
          );
          final thumbnailIndex = await _thumbnailService.loadIndex(rootPath);
          return _toEmojiItem(
            duplicateFile,
            category,
            rootPath: rootPath,
            thumbnailIndex: thumbnailIndex,
            activeSourcePaths: {duplicate},
            remark: null,
            isLink: true,
            homeCategory: homeCategory,
          );
        }
      }
    }

    String targetPath;
    String resultExtension;
    targetPath = _reserveTargetPath(
      categoryDirectory.path,
      sourceFile,
      detectedExtension,
    );
    await sourceFile.copy(targetPath);
    resultExtension = detectedExtension;

    if (sourceHash != null) {
      final relativeTarget = p.relative(targetPath, from: rootPath);
      _registerHash(sourceHash, relativeTarget);
      _sizeIndex.putIfAbsent(sourceSize, () => <String>{}).add(relativeTarget);
      _nameIndex
          .putIfAbsent(p.basename(targetPath), () => <String>{})
          .add(relativeTarget);
    }

    final thumbnailIndex = await _thumbnailService.loadIndex(rootPath);
    final lastModified = File(targetPath).statSync().modified.millisecondsSinceEpoch;
    final relativeSourcePath = p.relative(targetPath, from: rootPath);
    final thumbnailPath = await _thumbnailService.ensureThumbnail(
      rootPath: rootPath,
      filePath: targetPath,
      sourceModified: lastModified,
      index: thumbnailIndex,
    );
    await _thumbnailService.saveIndex(
      rootPath: rootPath,
      index: thumbnailIndex,
      activeSourcePaths: {...thumbnailIndex.keys, relativeSourcePath},
    );

    final mimeType = _mimeTypeForExtension(resultExtension);

    return EmojiItem(
      path: targetPath,
      name: p.basename(targetPath),
      mimeType: mimeType,
      category: category,
      lastModified: lastModified,
      thumbnailPath: thumbnailPath,
      fileSize: sourceSize,
      homeCategory: category,
    );
  }

  /// 源文件已在目标目录中: 原地复用并登记索引。
  Future<EmojiItem> _importInPlace({
    required File sourceFile,
    required String category,
    required String rootPath,
  }) async {
    final thumbnailIndex = await _thumbnailService.loadIndex(rootPath);
    return _toEmojiItem(
      sourceFile,
      category,
      rootPath: rootPath,
      thumbnailIndex: thumbnailIndex,
      activeSourcePaths: {p.relative(sourceFile.path, from: rootPath)},
    );
  }

  /// 查找库中与 [hash] 相同内容的已有图片相对路径。
  /// 先查注册表快速命中, 再用 size 预筛出候选逐个哈希精验。
  Future<String?> _findDuplicateRelativePath({
    required String rootPath,
    required String hash,
    required int size,
  }) async {
    final registered = _libraryIndex.hashes[hash];
    if (registered != null && File(p.join(rootPath, registered)).existsSync()) {
      return registered;
    }

    final candidates = _sizeIndex[size] ?? const <String>{};
    for (final candidate in candidates) {
      final candidateFile = File(p.join(rootPath, candidate));
      if (!candidateFile.existsSync()) {
        continue;
      }
      final candidateHash =
          _hashByPath[candidate] ?? await computeFileSha256(candidateFile);
      if (candidateHash == null) {
        continue;
      }
      _hashByPath[candidate] = candidateHash;
      _libraryIndex.registerHash(candidateHash, candidate);
      if (candidateHash == hash) {
        return candidate;
      }
    }
    return null;
  }

  /// 判断 [filePath] 是否直接位于 [directoryPath] 下 (不含子目录)。
  bool _isInsideDirectory(String filePath, String directoryPath) {
    return p.equals(
      p.dirname(p.canonicalize(filePath)),
      p.canonicalize(directoryPath),
    );
  }

  /// 从文件头魔数嗅探真实图片格式, 返回标准扩展名 (如 `.gif`);
  /// 内容不是受支持的图片时返回 null。
  /// QQ 等拖拽来源给出的临时文件扩展名不可信, 必须以字节内容为准。
  Future<String?> _detectImageFormat(File file) async {
    final RandomAccessFile raf;
    try {
      raf = await file.open();
    } catch (_) {
      return null;
    }
    try {
      final header = Uint8List(16);
      final bytesRead = await raf.readInto(header, 0, 16);
      if (bytesRead < 12) {
        return null;
      }
      // PNG: 89 50 4E 47
      if (header[0] == 0x89 &&
          header[1] == 0x50 &&
          header[2] == 0x4E &&
          header[3] == 0x47) {
        return '.png';
      }
      // JPEG: FF D8 FF
      if (header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF) {
        return '.jpg';
      }
      // GIF87a / GIF89a: GIF8[79]a
      if (header[0] == 0x47 &&
          header[1] == 0x49 &&
          header[2] == 0x46 &&
          header[3] == 0x38 &&
          (header[4] == 0x37 || header[4] == 0x39) &&
          header[5] == 0x61) {
        return '.gif';
      }
      // BMP: 42 4D ("BM")
      if (header[0] == 0x42 && header[1] == 0x4D) {
        return '.bmp';
      }
      // WebP: "RIFF"...."WEBP"
      if (header[0] == 0x52 &&
          header[1] == 0x49 &&
          header[2] == 0x46 &&
          header[3] == 0x46 &&
          header[8] == 0x57 &&
          header[9] == 0x45 &&
          header[10] == 0x42 &&
          header[11] == 0x50) {
        return '.webp';
      }
      // ISO-BMFF 系 (ftyp/heic 等) 不支持, 拒绝导入。
      return null;
    } finally {
      await raf.close();
    }
  }

  /// 选取一个不冲突的目标路径, 重名时在扩展名前追加 ` (1)`、` (2)` ...
  /// 扩展名来自内容嗅探, 而非 (可能错误的) 源文件名。
  String _reserveTargetPath(
    String directoryPath,
    File sourceFile,
    String extension,
  ) {
    final baseName = p.basenameWithoutExtension(sourceFile.path);
    var candidate = p.join(directoryPath, '$baseName$extension');
    var suffix = 1;
    while (File(candidate).existsSync()) {
      candidate = p.join(directoryPath, '$baseName ($suffix)$extension');
      suffix += 1;
    }
    return candidate;
  }

  /// 强制重新生成单张图片的缩略图并返回更新后的 [EmojiItem];
  /// 文件已不存在或解码失败时返回 null (右键菜单"刷新缩略图"用)。
  Future<EmojiItem?> refreshThumbnail(String rootPath, EmojiItem item) async {
    final file = File(item.path);
    if (!file.existsSync()) {
      return null;
    }

    final thumbnailIndex = await _thumbnailService.loadIndex(rootPath);
    await _thumbnailService.invalidate(
      rootPath: rootPath,
      filePath: item.path,
      index: thumbnailIndex,
    );

    final lastModified = file.statSync().modified.millisecondsSinceEpoch;
    final relativeSourcePath = p.relative(item.path, from: rootPath);
    final thumbnailPath = await _thumbnailService.ensureThumbnail(
      rootPath: rootPath,
      filePath: item.path,
      sourceModified: lastModified,
      index: thumbnailIndex,
    );

    await _thumbnailService.saveIndex(
      rootPath: rootPath,
      index: thumbnailIndex,
      // 单文件刷新, 保留索引中所有已有条目。
      activeSourcePaths: {...thumbnailIndex.keys, relativeSourcePath},
    );

    return item.copyWith(
      lastModified: lastModified,
      thumbnailPath: thumbnailPath,
    );
  }

  /// 递归汇总目录及其子目录中的备注表, 把相对文件名展开为绝对路径。
  Future<void> _loadFolderRemarksRecursive(
    Directory directory,
    Map<String, String> collector,
    {
    required Set<String> ignoredDirectoryNames,
  }) async {
    final remarks = await _loadRemarksForFolder(directory);
    for (final entry in remarks.entries) {
      final fullPath = p.join(directory.path, entry.key);
      collector[fullPath] = entry.value;
    }

    final children = directory.listSync().toList()
      ..sort(
        (left, right) => p
            .basename(left.path)
            .toLowerCase()
            .compareTo(p.basename(right.path).toLowerCase()),
      );

    for (final child in children) {
      if (child is! Directory) {
        continue;
      }
      final name = p.basename(child.path);
      if (ignoredDirectoryNames.contains(name)) {
        continue;
      }
      await _loadFolderRemarksRecursive(
        child,
        collector,
        ignoredDirectoryNames: ignoredDirectoryNames,
      );
    }
  }

  /// 读取单个目录的备注文件, 返回 文件名 -> 备注; 非法内容按空表处理。
  Future<Map<String, String>> _loadRemarksForFolder(Directory directory) async {
    final file = File(p.join(directory.path, _remarksFileName));
    if (!file.existsSync()) {
      return <String, String>{};
    }

    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) {
        return <String, String>{};
      }
      return json.map(
        (key, value) => MapEntry(key, value?.toString() ?? ''),
      )..removeWhere((key, value) => value.trim().isEmpty);
    } catch (_) {
      return <String, String>{};
    }
  }

  /// 解析分类对应的磁盘目录: "未分类" 即根目录, 其余为根目录下同名子目录。
  Directory _resolveCategoryDirectory(String rootPath, String category) {
    return category == uncategorized
        ? Directory(rootPath)
        : Directory(p.join(rootPath, category));
  }

  /// 把一个文件组装为 [EmojiItem], 途中确保缩略图存在、登记活跃路径,
  /// 并把文件的 size/文件名登记进去重与自愈索引。
  Future<EmojiItem> _toEmojiItem(
    File file,
    String category, {
    required String rootPath,
    required Map<String, ThumbnailEntry> thumbnailIndex,
    required Set<String> activeSourcePaths,
    String? remark,
    bool isLink = false,
    String? homeCategory,
  }) async {
    final extension = p.extension(file.path).toLowerCase();
    final stat = file.statSync();
    final lastModified = stat.modified.millisecondsSinceEpoch;
    final relativeSourcePath = p.relative(file.path, from: rootPath);
    activeSourcePaths.add(relativeSourcePath);
    final thumbnailPath = await _thumbnailService.ensureThumbnail(
      rootPath: rootPath,
      filePath: file.path,
      sourceModified: lastModified,
      index: thumbnailIndex,
    );
    _sizeIndex.putIfAbsent(stat.size, () => <String>{}).add(relativeSourcePath);
    _nameIndex
        .putIfAbsent(p.basename(file.path), () => <String>{})
        .add(relativeSourcePath);

    return EmojiItem(
      path: file.path,
      name: p.basename(file.path),
      mimeType: _mimeTypeForExtension(extension),
      category: category,
      lastModified: lastModified,
      thumbnailPath: thumbnailPath,
      remark: remark,
      fileSize: stat.size,
      homeCategory: homeCategory ?? category,
      isLink: isLink,
    );
  }

  /// 合并默认忽略目录、缩略图缓存目录与用户配置的忽略目录。
  Set<String> _buildIgnoredDirectories(Set<String> ignoredDirectoryNames) {
    return <String>{
      ...defaultIgnoredDirectories,
      EmojiThumbnailService.cacheDirectoryName,
      ...ignoredDirectoryNames.map((item) => item.trim()).where((item) => item.isNotEmpty),
    };
  }

  /// 从注册表反查重建 相对路径 -> 哈希 缓存。
  void _rebuildHashByPath() {
    _hashByPath.clear();
    _libraryIndex.hashes.forEach((hash, path) {
      _hashByPath[path] = hash;
    });
  }

  /// 登记哈希 (注册表 + 会话缓存)。
  void _registerHash(String hash, String relativePath) {
    _libraryIndex.registerHash(hash, relativePath);
    _hashByPath[relativePath] = hash;
  }

  /// 根据扩展名映射 MIME 类型。
  static String _mimeTypeForExtension(String extension) {
    return switch (extension) {
      '.gif' => 'image/gif',
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.bmp' => 'image/bmp',
      _ => 'image/jpeg',
    };
  }

  /// 实体文件所在目录对应的 home 分类名 (根目录直属文件为"未分类")。
  static String homeCategoryOf(String rootPath, String absolutePath) {
    final relative = p.relative(absolutePath, from: rootPath);
    final parts = p.split(relative);
    return parts.length <= 1 ? uncategorized : parts.first;
  }
}
