import 'dart:async';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用日志服务 (单例)。
///
/// - 每次启动在 `<root>/logs/` 下创建一份日志文件 `app_时间戳.log`;
///   根目录尚未选择时降级到应用支持目录。
/// - 日志先进入内存缓冲, 定时批量落盘, 减少 IO。
/// - 保留最近 [maxLogFiles] 份, 启动时静默清理更早的日志。
/// - 写日志失败一律静默忽略, 不影响主流程。
class EmojiLogService {
  EmojiLogService._();

  static final EmojiLogService instance = EmojiLogService._();

  static const logDirectoryName = 'logs';
  static const maxLogFiles = 30;
  static const _flushInterval = Duration(seconds: 2);

  File? _logFile;
  final List<String> _buffer = <String>[];
  Timer? _flushTimer;
  bool _flushing = false;

  /// 开始一次日志会话: 结束上一会话, 清理旧日志, 打开新日志文件。
  Future<void> startSession(String? rootPath) async {
    await _flush();
    _logFile = null;
    try {
      final directory = await _resolveLogDirectory(rootPath);
      await directory.create(recursive: true);
      await _cleanOldLogs(directory);
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      _logFile = File(p.join(directory.path, 'app_$stamp.log'));
      info('启动 emoji_manager, 根目录: ${rootPath ?? '(未选择)'}');
    } catch (_) {
      _logFile = null;
    }
  }

  void info(String message) => _log('INFO', message);

  void warn(String message) => _log('WARN', message);

  void error(String message, [Object? error, StackTrace? stackTrace]) {
    var text = message;
    if (error != null) {
      text = '$text | $error';
    }
    if (stackTrace != null) {
      text = '$text\n$stackTrace';
    }
    _log('ERROR', text);
  }

  void _log(String level, String message) {
    final stamp = DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(DateTime.now());
    _buffer.add('$stamp [$level] $message');
    _flushTimer ??= Timer(_flushInterval, _scheduledFlush);
    // 开发期同步输出, 便于观察。
    // ignore: avoid_print
    print('$stamp [$level] $message');
  }

  void _scheduledFlush() {
    _flushTimer = null;
    unawaited(_flush());
  }

  /// 把缓冲内容追加写入日志文件。
  Future<void> _flush() async {
    if (_flushing || _buffer.isEmpty || _logFile == null) {
      return;
    }
    _flushing = true;
    final chunk = _buffer.join('\n');
    _buffer.clear();
    try {
      await _logFile!.writeAsString(
        '$chunk\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // 写日志失败静默忽略。
    } finally {
      _flushing = false;
    }
  }

  Future<Directory> _resolveLogDirectory(String? rootPath) async {
    if (rootPath != null && rootPath.isNotEmpty) {
      return Directory(p.join(rootPath, logDirectoryName));
    }
    // 根目录未选择时降级到应用支持目录。
    final dir = await getApplicationSupportDirectory();
    return Directory(p.join(dir.path, 'emoji_manager', logDirectoryName));
  }

  /// 只保留最近 [maxLogFiles] 份日志。
  Future<void> _cleanOldLogs(Directory directory) async {
    final files = directory
        .listSync()
        .whereType<File>()
        .where((file) => p.extension(file.path) == '.log')
        .toList()
      ..sort(
        (left, right) => p
            .basename(left.path)
            .compareTo(p.basename(right.path)),
      );
    if (files.length <= maxLogFiles) {
      return;
    }
    for (final file in files.sublist(0, files.length - maxLogFiles)) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}
