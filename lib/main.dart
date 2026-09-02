import 'package:flutter/widgets.dart';

import 'app.dart';

/// 应用入口。
///
/// 表情包管理器以常驻小窗口为主, 内存占用是重点优化目标,
/// 因此在启动时主动调小全局图片缓存上限, 避免大量缩略图解码后驻留内存。
void main() {
  // 确保 binding 初始化完成, 后续启动阶段可安全访问 PaintingBinding 等服务。
  WidgetsFlutterBinding.ensureInitialized();

  // 压缩全局图片缓存: 最多缓存 64 张、总字节上限 24MB。
  // 网格/分类/预览各自按实际显示尺寸解码, 不依赖全尺寸原图缓存。
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 64;
  imageCache.maximumSizeBytes = 24 << 20;

  runApp(const MyApp());
}
