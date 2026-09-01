import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/emoji_item.dart';
import '../models/emoji_scan_result.dart';
import '../models/sort_order.dart';
import 'emoji_thumbnail_service.dart';

class ImportResult {
  const ImportResult({
    required this.imported,
    required this.skipped,
  });

  final List<EmojiItem> imported;
  final int skipped;
}

class EmojiRepository {
  EmojiRepository({
    EmojiThumbnailService? thumbnailService,
  }) : _thumbnailService = thumbnailService ?? EmojiThumbnailService();

  static const uncategorized = '未分类';
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

  bool _isImageFile(String filePath) {
    return _imageExtensions.contains(p.extension(filePath).toLowerCase());
  }

  /// Imports dropped files/folders into the directory backing [category].
  /// Folders are expanded recursively; non-image files are skipped.
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

  List<String> _collectImagePathsInDirectory(Directory directory) {
    final result = <String>[];
    for (final child in directory.listSync()) {
      final name = p.basename(child.path);
      if (child is Directory) {
        // Skip hidden folders such as .sync / cache directories.
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

  /// Copies a dropped image file into the directory backing [category] and
  /// returns the resulting [EmojiItem]. The real format is sniffed from the
  /// file header because drag sources (e.g. QQ) often hand out temp files
  /// whose extension does not match the content. When the source file already
  /// lives in the target directory it is reused in place instead of being
  /// copied. Returns null when the source is missing or is not a supported
  /// image.
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
      // Reused in place: keep the on-disk name so it stays consistent with the
      // directory scanner (which keys off the file extension).
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

  bool _isInsideDirectory(String filePath, String directoryPath) {
    return p.equals(
      p.dirname(p.canonicalize(filePath)),
      p.canonicalize(directoryPath),
    );
  }

  /// Sniffs the real image format from the file header. Returns the canonical
  /// extension (e.g. `.gif`) or null when the content is not a supported
  /// image. Drag sources such as QQ hand out temp files whose extension lies
  /// about the actual bytes, so the name alone cannot be trusted.
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
      if (header[0] == 0x89 &&
          header[1] == 0x50 &&
          header[2] == 0x4E &&
          header[3] == 0x47) {
        return '.png';
      }
      if (header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF) {
        return '.jpg';
      }
      if (header[0] == 0x47 &&
          header[1] == 0x49 &&
          header[2] == 0x46 &&
          header[3] == 0x38 &&
          (header[4] == 0x37 || header[4] == 0x39) &&
          header[5] == 0x61) {
        return '.gif';
      }
      if (header[0] == 0x42 && header[1] == 0x4D) {
        return '.bmp';
      }
      // RIFF....WEBP
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
      // ISO-BMFF variant: ....ftypimage/heic etc. — not supported, reject.
      return null;
    } finally {
      await raf.close();
    }
  }

  /// Picks a non-colliding destination path, appending ` (1)`, ` (2)`, ...
  /// before the extension when the name is already taken. The extension comes
  /// from content detection rather than the (possibly wrong) source name.
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

  /// Force-regenerates the thumbnail for a single image and returns the
  /// updated [EmojiItem]. Returns null when the file is gone or the image
  /// cannot be decoded.
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
      // Keep every known entry; this is a single-file refresh.
      activeSourcePaths: {...thumbnailIndex.keys, relativeSourcePath},
    );

    return item.copyWith(
      lastModified: lastModified,
      thumbnailPath: thumbnailPath,
    );
  }

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

  Directory _resolveCategoryDirectory(String rootPath, String category) {
    return category == uncategorized
        ? Directory(rootPath)
        : Directory(p.join(rootPath, category));
  }

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

  Set<String> _buildIgnoredDirectories(Set<String> ignoredDirectoryNames) {
    return <String>{
      ...defaultIgnoredDirectories,
      EmojiThumbnailService.cacheDirectoryName,
      ...ignoredDirectoryNames.map((item) => item.trim()).where((item) => item.isNotEmpty),
    };
  }
}
