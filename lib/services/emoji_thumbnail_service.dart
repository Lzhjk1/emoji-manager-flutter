import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class EmojiThumbnailService {
  static const cacheDirectoryName = '.emoji_manager';
  static const thumbnailDirectoryName = 'thumbnails';
  static const indexFileName = 'thumbnail_index.json';
  static const thumbnailMaxSize = 256;
  static const thumbnailQuality = 80;

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

  Future<String?> ensureThumbnail({
    required String rootPath,
    required String filePath,
    required int sourceModified,
    required Map<String, ThumbnailEntry> index,
  }) async {
    final relativeSourcePath = p.relative(filePath, from: rootPath);
    final extension = p.extension(filePath).toLowerCase();
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
        final encoded = await compute(
          _generateThumbnailBytes,
          filePath,
        );
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

  /// Removes the cached thumbnail (file + index entry) for [filePath] so the
  /// next [ensureThumbnail] call regenerates it from the source image.
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

  Directory cacheDirectory(String rootPath) {
    return Directory(p.join(rootPath, cacheDirectoryName));
  }

  File _indexFile(String rootPath) {
    return File(p.join(rootPath, cacheDirectoryName, indexFileName));
  }

  String _safeKeyForPath(String relativePath) {
    return base64Url.encode(utf8.encode(relativePath)).replaceAll('=', '');
  }
}

class ThumbnailEntry {
  const ThumbnailEntry({
    required this.sourceModified,
    required this.thumbnailRelativePath,
  });

  final int sourceModified;
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

/// Reads and decodes [filePath] in a background isolate, then crops, resizes
/// and JPEG-encodes the thumbnail there so the heavy bitmap buffers are
/// released with the isolate instead of growing the main heap.
Uint8List? _generateThumbnailBytes(String filePath) {
  try {
    final sourceBytes = File(filePath).readAsBytesSync();
    final decoded = img.decodeImage(sourceBytes);
    if (decoded == null) {
      return null;
    }

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
