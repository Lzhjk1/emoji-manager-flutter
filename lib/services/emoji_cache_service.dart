import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/emoji_scan_result.dart';

/// 扫描结果的应用级缓存。
///
/// 把 [EmojiScanResult] 按 rootPath 为键持久化到应用支持目录,
/// 下次启动同一表情库时可跳过完整扫描直接加载, 加快冷启动。
class EmojiCacheService {
  /// 缓存结构版本: 字段变化时 +1, 使旧缓存整体失效重建。
  static const cacheSchemaVersion = 2;

  /// 加载与 [rootPath] 匹配的缓存; 不存在、根路径不一致或内容损坏时返回 null。
  Future<EmojiScanResult?> load(String rootPath) async {
    final file = await _cacheFileForPath(rootPath);
    if (!file.existsSync()) {
      return null;
    }

    try {
      final text = await file.readAsString();
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) {
        return null;
      }

      if (json['schemaVersion'] != cacheSchemaVersion) {
        return null;
      }

      if (json['rootPath'] != rootPath) {
        return null;
      }

      final payload = json['payload'];
      if (payload is! Map<String, dynamic>) {
        return null;
      }

      return EmojiScanResult.fromJson(payload);
    } catch (_) {
      return null;
    }
  }

  /// 保存一份扫描结果到缓存文件。
  Future<void> save(String rootPath, EmojiScanResult result) async {
    final file = await _cacheFileForPath(rootPath);
    await file.parent.create(recursive: true);
    final payload = <String, dynamic>{
      'schemaVersion': cacheSchemaVersion,
      'rootPath': rootPath,
      'payload': result.toJson(),
    };
    await file.writeAsString(jsonEncode(payload));
  }

  /// 由 rootPath 生成缓存文件名 (base64Url, 去掉非法字符 '='), 一个根路径一个文件。
  Future<File> _cacheFileForPath(String rootPath) async {
    final directory = await getApplicationSupportDirectory();
    final safeKey = base64Url.encode(utf8.encode(rootPath)).replaceAll('=', '');
    return File(p.join(directory.path, 'emoji_manager', '$safeKey.json'));
  }
}
