import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui/app_theme.dart';
import 'ui/home_shell.dart';

/// 全局 UI 字体：Windows 用微软雅黑，移动端（iOS/Android）用系统默认
/// （iOS 无微软雅黑，指定会回退；让系统字体现成）。
String? _uiFont() =>
    defaultTargetPlatform == TargetPlatform.windows ? 'Microsoft YaHei' : null;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // 视频播放（libmpv）
  final sp = await SharedPreferences.getInstance();
  final a = sp.getInt('accent_color');
  if (a != null) AppTheme.accent.value = Color(a);
  AppTheme.darkMode.value = sp.getInt('app_dark_mode') ?? 0;
  runApp(const ProviderScope(child: ReadingApp()));
}

class ReadingApp extends StatelessWidget {
  const ReadingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: AppTheme.accent,
      builder: (context, accent, _) => ValueListenableBuilder<int>(
        valueListenable: AppTheme.darkMode,
        builder: (context, dm, _) {
          final theme = ThemeData(
            colorScheme:
                ColorScheme.fromSeed(seedColor: accent),
            useMaterial3: true,
            // 全局统一字体（桌面用微软雅黑，移动端系统默认）；
            // 书籍正文由阅读器「字体」设置单独控制
            fontFamily: _uiFont(),
          );
          final darkTheme = ThemeData(
            colorScheme: ColorScheme.fromSeed(
                seedColor: accent, brightness: Brightness.dark),
            useMaterial3: true,
            fontFamily: _uiFont(),
          );
          return MaterialApp(
            title: '悦读',
            debugShowCheckedModeBanner: false,
            themeMode: AppTheme.themeMode,
            theme: theme,
            darkTheme: darkTheme,
            home: const HomeShell(),
          );
        },
      ),
    );
  }
}
