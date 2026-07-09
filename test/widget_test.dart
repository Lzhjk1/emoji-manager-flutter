import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:emoji_manager_flutter/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows welcome state before selecting directory', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('选择你的表情包根目录'), findsOneWidget);
    expect(find.text('选择表情包目录'), findsOneWidget);
  });
}
