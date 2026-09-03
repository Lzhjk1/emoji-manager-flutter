import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 缩略图缓存服务。
///
/// 在表情库根目录的 `.emoji_manager/thumbnails/` 下存放 256px JPEG 缩略图,
/// 并用 `thumbnail_index.json` 记录 源图相对路径 -> (源图修改时间, 缩略图路径),
/// 以"源图修改时间是否变化"判断缩略图是否需要重新生成。
/// 解码用引擎按目标尺寸 (≤256px) 缩放解码, 避免全尺寸位图瞬态把
/// isolate 页池/工作集推高; 裁剪/编码在 256px 小图上进行, 开销可忽略。
class EmojiThumbnailService {
  /// 表情库内的缓存目录名。
  static const cacheDirectoryName = '.emoji_manager';
  static const thumbnailDirectoryName = 'thumbnails';
  static const indexFileName = 'thumbnail_index.json';
  static const thumbnailMaxSize = 256;
  static const thumbnailQuality = 80;

  /// 从磁盘加载缩略图索引; 文件缺失或损坏时返回空表。
  Future<Map<String, ThumbnailEntry>> loadIndex(String rootPath) async {
    final file = _indexFile(rootPath);
    if (!file.existsSync()) {
      return <String, ThumbnailEntry>{};
    }

    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) {
        return <String, ThumbnailEntry>{};
      }

      final rawEntries = json['entries'];
      if (rawEntries is! Map<String, dynamic>) {
        return <String, ThumbnailEntry>{};
      }

      return rawEntries.map(
        (key, value) => MapEntry(
          key,
          ThumbnailEntry.fromJson(value as Map<String, dynamic>? ?? const {}),
        ),
      );
    } catch (_) {
      return <String, ThumbnailEntry>{};
    }
  }

  /// 确保源图的缩略图存在, 返回缩略图绝对路径 (失败返回 null)。
  ///
  /// - GIF 不生成缩略图 (直接从索引移除, UI 显示动图第一帧);
  /// - 源图未变、缩略图在且路径未迁移时直接复用缓存;
  /// - 需要更新时在后台 isolate 重新生成, 并清理迁移前的旧文件。
  Future<String?> ensureThumbnail({
    required String rootPath,
    required String filePath,
    required int sourceModified,
    required Map<String, ThumbnailEntry> index,
  }) async {
    final relativeSourcePath = p.relative(filePath, from: rootPath);
    final extension = p.extension(filePath).toLowerCase();
    // GIF 保持动图展示, 不做静态缩略图。
    if (extension == '.gif') {
      index.remove(relativeSourcePath);
      return null;
    }
    final existingEntry = index[relativeSourcePath];
    final thumbnailRelativePath = p.join(
      cacheDirectoryName,
      thumbnailDirectoryName,
      '${_safeKeyForPath(relativeSourcePath)}.jpg',
    );
    final thumbnailPath = p.join(rootPath, thumbnailRelativePath);
    final thumbnailFile = File(thumbnailPath);
    final previousThumbnailRelativePath = existingEntry?.thumbnailRelativePath;
    final needsPathMigration =
        previousThumbnailRelativePath != null &&
        previousThumbnailRelativePath != thumbnailRelativePath;

    final needsUpdate =
        existingEntry == null ||
        existingEntry.sourceModified != sourceModified ||
        needsPathMigration ||
        !thumbnailFile.existsSync();

    try {
      if (needsUpdate) {
        // 引擎按目标尺寸 (≤256px) 缩放解码, 在主 isolate 执行
        // (引擎图像解码器注册表无法在 compute 的后台 isolate 中访问);
        // JPEG/WebP 走解码器原生缩放, 单张瞬态 <1MB, 无卡顿。
        final sourceBytes = await File(filePath).readAsBytes();
        final decoded = await _decodeWithEngine(sourceBytes);
        final encoded = decoded == null ? null : _cropAndEncode(decoded);
        if (encoded == null) {
          return null;
        }

        await thumbnailFile.parent.create(recursive: true);
        await thumbnailFile.writeAsBytes(encoded, flush: true);
        if (needsPathMigration) {
          final previousFile = File(
            p.join(rootPath, previousThumbnailRelativePath),
          );
          if (previousFile.existsSync()) {
            await previousFile.delete();
          }
        }
      }
    } catch (_) {
      if (thumbnailFile.existsSync()) {
        await thumbnailFile.delete();
      }
      index.remove(relativeSourcePath);
      return null;
    }

    index[relativeSourcePath] = ThumbnailEntry(
      sourceModified: sourceModified,
      thumbnailRelativePath: thumbnailRelativePath,
    );
    return thumbnailPath;
  }

  /// 移除 [filePath] 的缩略图缓存 (文件 + 索引条目),
  /// 下次 [ensureThumbnail] 会重新生成。
  Future<void> invalidate({
    required String rootPath,
    required String filePath,
    required Map<String, ThumbnailEntry> index,
  }) async {
    final relativeSourcePath = p.relative(filePath, from: rootPath);
    final entry = index.remove(relativeSourcePath);
    final thumbnailPath = entry?.thumbnailRelativePath ??
        p.join(
          cacheDirectoryName,
          thumbnailDirectoryName,
          '${_safeKeyForPath(relativeSourcePath)}.jpg',
        );
    final thumbnailFile = File(p.join(rootPath, thumbnailPath));
    if (thumbnailFile.existsSync()) {
      await thumbnailFile.delete();
    }
  }

  /// 把索引写回磁盘, 并清理不在 [activeSourcePaths] 中的过期条目及其缩略图文件
  /// (源图被删除/移动后遗留的缓存)。
  Future<void> saveIndex({
    required String rootPath,
    required Map<String, ThumbnailEntry> index,
    required Set<String> activeSourcePaths,
  }) async {
    final staleKeys = index.keys
        .where((key) => !activeSourcePaths.contains(key))
        .toList(growable: false);
    for (final key in staleKeys) {
      final entry = index.remove(key);
      if (entry == null) {
        continue;
      }
      final thumbnailFile = File(p.join(rootPath, entry.thumbnailRelativePath));
      if (thumbnailFile.existsSync()) {
        await thumbnailFile.delete();
      }
    }

    final file = _indexFile(rootPath);
    await file.parent.create(recursive: true);
    final payload = <String, dynamic>{
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'entries': index.map(
        (key, value) => MapEntry<String, dynamic>(key, value.toJson()),
      ),
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
  }

  /// 表情库内的缩略图缓存目录。
  Directory cacheDirectory(String rootPath) {
    return Directory(p.join(rootPath, cacheDirectoryName));
  }

  /// 缩略图索引文件路径。
  File _indexFile(String rootPath) {
    return File(p.join(rootPath, cacheDirectoryName, indexFileName));
  }

  /// 由相对路径生成文件名安全的缓存 key (base64Url, 去掉 '=')。
  String _safeKeyForPath(String relativePath) {
    return base64Url.encode(utf8.encode(relativePath)).replaceAll('=', '');
  }
}

/// 缩略图索引条目: 记录生成时的源图修改时间, 用于判断缓存是否过期。
class ThumbnailEntry {
  const ThumbnailEntry({
    required this.sourceModified,
    required this.thumbnailRelativePath,
  });

  /// 生成时的源图最后修改时间 (毫秒时间戳)。
  final int sourceModified;

  /// 缩略图相对于表情库根目录的路径。
  final String thumbnailRelativePath;

  factory ThumbnailEntry.fromJson(Map<String, dynamic> json) {
    return ThumbnailEntry(
      sourceModified: json['sourceModified'] as int? ?? 0,
      thumbnailRelativePath: json['thumbnailRelativePath'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'sourceModified': sourceModified,
      'thumbnailRelativePath': thumbnailRelativePath,
    };
  }
}

/// 居中裁成正方形并缩放到 [EmojiThumbnailService.thumbnailMaxSize],
/// 编码为 JPEG。
Uint8List? _cropAndEncode(img.Image decoded) {
  try {
    final cropSize = decoded.width < decoded.height
        ? decoded.width
        : decoded.height;
    final cropX = ((decoded.width - cropSize) / 2).floor();
    final cropY = ((decoded.height - cropSize) / 2).floor();
    final cropped = img.copyCrop(
      decoded,
      x: cropX,
      y: cropY,
      width: cropSize,
      height: cropSize,
    );
    final resized = img.copyResize(
      cropped,
      width: EmojiThumbnailService.thumbnailMaxSize,
      height: EmojiThumbnailService.thumbnailMaxSize,
      interpolation: img.Interpolation.linear,
    );
    return Uint8List.fromList(
      img.encodeJpg(
        resized,
        quality: EmojiThumbnailService.thumbnailQuality,
      ),
    );
  } catch (_) {
    return null;
  }
}

/// 引擎解码: 用 Flutter 引擎原生解码器按目标尺寸缩放解码
/// (JPEG 走 DCT 域缩放、WebP 走原生降分辨率, 不物化全尺寸位图;
/// PNG 无原生缩放, 引擎内部先解码再缩, 瞬态由引擎自行管理)。
/// 等比缩放至最长边不超过 [EmojiThumbnailService.thumbnailMaxSize],
/// 再转回 [img.Image] 以复用居中裁剪与 JPEG 编码逻辑。
/// 注意: 必须在主 isolate 调用 (后台 isolate 无法访问解码器注册表)。
Future<img.Image?> _decodeWithEngine(Uint8List sourceBytes) async {
  ui.Codec? codec;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(sourceBytes);
    // 注意: instantiateImageCodecWithSize 成功与否都会接管并释放 buffer,
    // 调用方不得再次 dispose。
    final maxSize = EmojiThumbnailService.thumbnailMaxSize;
    try {
      codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          final scale =
              maxSize / math.max(intrinsicWidth, intrinsicHeight);
          return ui.TargetImageSize(
            width: (intrinsicWidth * scale).round(),
            height: (intrinsicHeight * scale).round(),
          );
        },
      );
    } catch (_) {
      return null;
    }
    final frame = await codec.getNextFrame();
    final ui.Image image = frame.image;
    final width = image.width;
    final height = image.height;
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    if (data == null) {
      return null;
    }
    return img.Image.fromBytes(
      width: width,
      height: height,
      bytes: data.buffer,
      bytesOffset: data.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
  }
}
