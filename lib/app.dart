import 'package:flutter/material.dart';

import 'pages/emoji_home_page.dart';

/// 应用根 Widget, 负责配置全局主题 (Material 3 深色方案 + 微软雅黑字体)。
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 基础表面色 (窗口底色)、面板色 (卡片/输入框) 与强调色。
    const baseSurface = Color(0xFF111315);
    const panelSurface = Color(0xFF1A1D21);
    const accentColor = Color(0xFF90CAF9);

    final colorScheme = ColorScheme.fromSeed(
      seedColor: accentColor,
      brightness: Brightness.dark,
      surface: baseSurface,
    );

    return MaterialApp(
      title: '表情包管理器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'Microsoft YaHei UI',
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: baseSurface,
        cardTheme: const CardThemeData(
          color: panelSurface,
          margin: EdgeInsets.zero,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: baseSurface,
          surfaceTintColor: Colors.transparent,
        ),
        chipTheme: ChipThemeData.fromDefaults(
          secondaryColor: accentColor,
          brightness: Brightness.dark,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: panelSurface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: colorScheme.primary),
          ),
        ),
      ),
      home: const EmojiHomePage(),
    );
  }
}
