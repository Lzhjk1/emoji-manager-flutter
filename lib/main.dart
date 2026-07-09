import 'package:flutter/widgets.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 300;
  imageCache.maximumSizeBytes = 96 << 20;
  runApp(const MyApp());
}
