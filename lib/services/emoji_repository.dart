import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/emoji_item.dart';
import '../models/emoji_scan_result.dart';
import '../models/sort_order.dart';
import 'emoji_thumbnail_service.dart';

/// 导入结果: 成功导入的表情列表与被跳过的数量 (非图片或读取失败)。
class ImportResult {
  const ImportResult({
    required this.imported,
    required this.skipped,
  });

  final List<EmojiItem> imported;
  final int skipped;
}

/// 表情库的磁盘数据访问层。
///
/// 目录约定: [rootPath] 为表情库根目录, 根目录下每个子目录是一个分类,
/// 根目录直属的图片属于"未分类"。每个分类目录内可包含:
/// - `emoji_image_order.json`: 手动排序文件
/// - `emoji_remarks.json`: 图片备注表 (文件名 -> 备注)
/// - `.emoji_manager/`: 缩略图缓存与索引 (由 [EmojiThumbnailService] 管理)
class EmojiRepository {
  EmojiRepository({
    EmojiThumbnailService? thumbnailService,
  }) : _thumbnailService = thumbnailService ?? EmojiThumbnailService();

  /// 根目录直属图片归属的虚拟分类名。
  static const uncategorized = '未分类';

  /// 始终忽略的目录名 (同步工具目录等)。
  static const defaultIgnoredDirectories = <String>{'.sync'};
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

  /// 扫描整个表情库, 返回分类 -> 表情列表 及分类元数据。
  ///
  /// 同时完成三件事:
  /// 1. 递归收集每个分类下的图片并组装 [EmojiItem];
  /// 2. 确保缩略图存在 (必要时在后台 isolate 生成);
  /// 3. 以本次扫描到的源图集合清理缩略图索引中的过期条目。
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

    await _thumbnailService.saveIndex(
      rootPath: rootPath,
      index: thumbnailIndex,
      activeSourcePaths: activeSourcePaths,
    );

    return EmojiScanResult(
      itemsByCategory: itemsByCategory,
      categoryMetadata: metadata,
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
  Future<List<EmojiItem>> sortCategoryItems({
    required String rootPath,
    required String category,
    required List<EmojiItem> items,
    required SortOrder sortOrder,
  }) async {
    if (items.isEmpty) {
      return items;
    }

    switch (sortOrder) {
      case SortOrder.byName:
        final sorted = [...items]..sort(
            (left, right) => left.name.toLowerCase().compareTo(right.name.toLowerCase()),
          );
        return sorted;
      case SortOrder.byTime:
        final sorted = [...items]
          ..sort((left, right) => right.lastModified.compareTo(left.lastModified));
        return sorted;
      case SortOrder.byOrder:
        final order = await readOrderForCategory(rootPath, category);
        if (order.isEmpty) {
          final sorted = [...items]
            ..sort(
              (left, right) =>
                  left.name.toLowerCase().compareTo(right.name.toLowerCase()),
            );
          return sorted;
        }

        final orderIndex = <String, int>{
          for (var index = 0; index < order.length; index++) order[index]: index,
        };
        final sorted = [...items]
          ..sort((left, right) {
            final leftIndex = orderIndex[left.name] ?? 1 << 30;
            final rightIndex = orderIndex[right.name] ?? 1 << 30;
            if (leftIndex != rightIndex) {
              return leftIndex.compareTo(rightIndex);
            }
            return left.name.toLowerCase().compareTo(right.name.toLowerCase());
          });
        return sorted;
    }
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

  /// 删除图片文件, 并同步清理其备注条目、顺序文件条目与缩略图缓存。
  /// 文件不存在或删除失败时返回 false。
  Future<bool> deleteImage({
    required String rootPath,
    required String category,
    required EmojiItem item,
  }) async {
    final imageFile = File(item.path);
    if (!imageFile.existsSync()) {
      return false;
    }

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

    // 4. 删除图片文件本身。
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
  /// 目录会递归展开; 非图片文件被跳过。
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
    for (final path in imagePaths) {
      final item = await _importImageToCategory(
        rootPath: rootPath,
        category: category,
        sourcePath: path,
      );
      if (item == null) {
        skipped += 1;
      } else {
        imported.add(item);
      }
    }
    return ImportResult(imported: imported, skipped: skipped);
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

    String targetPath;
    String resultExtension;
    if (_isInsideDirectory(sourcePath, categoryDirectory.path)) {
      // 原地复用: 保留磁盘上的原文件名, 与目录扫描器的扩展名约定保持一致。
      targetPath = sourceFile.path;
      resultExtension = p.extension(sourceFile.path).toLowerCase();
    } else {
      targetPath = _reserveTargetPath(
        categoryDirectory.path,
        sourceFile,
        detectedExtension,
      );
      await sourceFile.copy(targetPath);
      resultExtension = detectedExtension;
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

    final mimeType = switch (resultExtension) {
      '.gif' => 'image/gif',
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.bmp' => 'image/bmp',
      _ => 'image/jpeg',
    };

    return EmojiItem(
      path: targetPath,
      name: p.basename(targetPath),
      mimeType: mimeType,
      category: category,
      lastModified: lastModified,
      thumbnailPath: thumbnailPath,
    );
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

  /// 把一个文件组装为 [EmojiItem], 途中确保缩略图存在并登记活跃路径。
  Future<EmojiItem> _toEmojiItem(
    File file,
    String category, {
    required String rootPath,
    required Map<String, ThumbnailEntry> thumbnailIndex,
    required Set<String> activeSourcePaths,
    String? remark,
  }) async {
    final extension = p.extension(file.path).toLowerCase();
    final mimeType = switch (extension) {
      '.gif' => 'image/gif',
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.bmp' => 'image/bmp',
      _ => 'image/jpeg',
    };
    final lastModified = file.statSync().modified.millisecondsSinceEpoch;
    final relativeSourcePath = p.relative(file.path, from: rootPath);
    activeSourcePaths.add(relativeSourcePath);
    final thumbnailPath = await _thumbnailService.ensureThumbnail(
      rootPath: rootPath,
      filePath: file.path,
      sourceModified: lastModified,
      index: thumbnailIndex,
    );

    return EmojiItem(
      path: file.path,
      name: p.basename(file.path),
      mimeType: mimeType,
      category: category,
      lastModified: lastModified,
      thumbnailPath: thumbnailPath,
      remark: remark,
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
}
