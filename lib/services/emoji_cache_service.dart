import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/emoji_scan_result.dart';

class EmojiCacheService {
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

  Future<void> save(String rootPath, EmojiScanResult result) async {
    final file = await _cacheFileForPath(rootPath);
    await file.parent.create(recursive: true);
    final payload = <String, dynamic>{
      'rootPath': rootPath,
      'payload': result.toJson(),
    };
    await file.writeAsString(jsonEncode(payload));
  }

  Future<File> _cacheFileForPath(String rootPath) async {
    final directory = await getApplicationSupportDirectory();
    final safeKey = base64Url.encode(utf8.encode(rootPath)).replaceAll('=', '');
    return File(p.join(directory.path, 'emoji_manager', '$safeKey.json'));
  }
}
