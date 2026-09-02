import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// library.json 的 link 记录: 一张图被加入的额外分类 (不含 home 分类)。
class LibraryLink {
  LibraryLink({
    required this.path,
    required this.hash,
    required this.size,
    required this.addedAt,
    List<String> categories = const [],
    this.missing = false,
  }) : categories = [...categories];

  /// 图片相对 root 的路径 (link 主键)。
  String path;

  /// 内容 SHA-256 (十六进制), 自愈依据。
  String hash;

  /// 文件字节数, 自愈候选预筛依据。
  int size;

  /// 加入时间戳。
  int addedAt;

  /// 额外分类列表。
  List<String> categories;

  /// 自愈失败标记: 文件已丢失且找不到改名后的新位置。
  bool missing;

  factory LibraryLink.fromJson(Map<String, dynamic> json) {
    return LibraryLink(
      path: json['path'] as String? ?? '',
      hash: json['hash'] as String? ?? '',
      size: json['size'] as int? ?? 0,
      addedAt: json['addedAt'] as int? ?? 0,
      categories:
          (json['categories'] as List<dynamic>? ?? const <dynamic>[])
              .whereType<String>()
              .toList(),
      missing: json['missing'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'path': path,
      'hash': hash,
      'size': size,
      'addedAt': addedAt,
      'categories': categories,
      'missing': missing,
    };
  }
}

/// 中央索引服务: 管理 `<root>/library.json`。
///
/// 索引只做"加法"协调, 不改变目录扫描结果; 丢失或损坏时系统可降级为
/// 纯目录扫描行为。写入采用 tmp + rename 原子替换。
class EmojiLibraryIndex {
  static const fileName = 'library.json';
  static const schemaVersion = 2;

  /// 内容哈希注册表: hash -> 实体文件当前相对路径 (仅登记应用经手过的文件)。
  final Map<String, String> hashes = {};

  /// 附加分类链接, 以相对路径为主键。
  final Map<String, LibraryLink> links = {};

  /// 加载索引; 文件缺失/损坏/schema 不符时返回空索引 (降级)。
  Future<void> load(String rootPath) async {
    hashes.clear();
    links.clear();
    final file = _indexFile(rootPath);
    if (!file.existsSync()) {
      return;
    }

    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) {
        return;
      }
      if (json['schemaVersion'] != schemaVersion) {
        return;
      }

      final rawHashes = json['hashes'];
      if (rawHashes is Map<String, dynamic>) {
        rawHashes.forEach((key, value) {
          if (value is String && key.isNotEmpty) {
            hashes[key] = value;
          }
        });
      }

      final rawLinks = json['links'];
      if (rawLinks is List<dynamic>) {
        for (final entry in rawLinks) {
          if (entry is Map<String, dynamic>) {
            final link = LibraryLink.fromJson(entry);
            if (link.path.isNotEmpty) {
              links[link.path] = link;
            }
          }
        }
      }
    } catch (_) {
      // 损坏即降级为空索引。
      hashes.clear();
      links.clear();
    }
  }

  /// 原子保存索引。
  Future<void> save(String rootPath) async {
    final file = _indexFile(rootPath);
    final tmp = File('${file.path}.tmp');
    final payload = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'hashes': hashes,
      'links': links.values.map((link) => link.toJson()).toList(),
    };
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // rename 失败 (如跨卷等) 时退化为直接写。
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      if (tmp.existsSync()) {
        await tmp.delete();
      }
    }
  }

  /// 登记一个文件的哈希。
  void registerHash(String hash, String relativePath) {
    if (hash.isNotEmpty && relativePath.isNotEmpty) {
      hashes[hash] = relativePath;
    }
  }

  /// 文件删除/更名后移除指向旧路径的注册表条目。
  void forgetHashByPath(String relativePath) {
    hashes.removeWhere((_, value) => value == relativePath);
  }

  /// 为图片在 [category] 中建立 (或扩展) link; 已含该分类时返回 false。
  bool addLink({
    required String relativePath,
    required String category,
    required String hash,
    required int size,
  }) {
    final link = links[relativePath];
    if (link != null) {
      if (link.categories.contains(category)) {
        return false;
      }
      link.categories.add(category);
      link.missing = false;
      return true;
    }
    links[relativePath] = LibraryLink(
      path: relativePath,
      hash: hash,
      size: size,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      categories: [category],
    );
    return true;
  }

  /// 从 [category] 中移除图片的 link; categories 清空后整条移除。
  /// 返回是否发生了移除。
  bool removeLinkFromCategory({
    required String relativePath,
    required String category,
  }) {
    final link = links[relativePath];
    if (link == null || !link.categories.contains(category)) {
      return false;
    }
    link.categories.remove(category);
    if (link.categories.isEmpty) {
      links.remove(relativePath);
    }
    return true;
  }

  /// 整条移除 link (文件被删除时调用)。
  void removeLink(String relativePath) {
    links.remove(relativePath);
  }

  /// 自愈成功后更新 link 与注册表中的路径。
  void updateLinkPath(String oldPath, String newPath) {
    final link = links.remove(oldPath);
    if (link != null) {
      link.path = newPath;
      links[newPath] = link;
    }
    hashes.removeWhere((_, value) => value == oldPath);
  }

  File _indexFile(String rootPath) {
    return File(p.join(rootPath, fileName));
  }
}

/// 流式计算文件 SHA-256 (十六进制); 读取失败返回 null。
Future<String?> computeFileSha256(File file) async {
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final digest = await _hashStream(raf);
    return digest;
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

Future<String> _hashStream(RandomAccessFile raf) async {
  final sink = _DigestSink();
  var input = sha256.startChunkedConversion(sink);
  const chunkSize = 256 * 1024;
  final buffer = Uint8List(chunkSize);
  while (true) {
    final bytesRead = await raf.readInto(buffer);
    if (bytesRead <= 0) {
      break;
    }
    input.add(Uint8List.sublistView(buffer, 0, bytesRead));
  }
  input.close();
  return sink.digest.toString();
}

/// 捕获分块哈希转换的最终结果。
class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get digest =>
      _digest ?? (throw StateError('哈希计算未完成'));

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}
