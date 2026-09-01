import 'package:flutter/widgets.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 64;
  imageCache.maximumSizeBytes = 24 << 20;
  runApp(const MyApp());
}
