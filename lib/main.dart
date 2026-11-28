import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui/app_theme.dart';
import 'ui/home_shell.dart';
import 'utils/app_navigator.dart';

/// 全局 UI 字体：Windows 用微软雅黑，移动端（iOS/Android）用系统默认
/// （iOS 无微软雅黑，指定会回退；让系统字体现成）。
String? _uiFont() =>
    defaultTargetPlatform == TargetPlatform.windows ? 'Microsoft YaHei' : null;

/// 主题配色：强调色仍由 seed 决定，但显式中性 surface 色阶，
/// 让页面底色（surfaceContainerLow）与卡片（surface）有清晰层次。
ColorScheme _appColorScheme(Color seed, Brightness brightness) {
  final base = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  if (brightness == Brightness.light) {
    return base.copyWith(
      surfaceContainerLowest: const Color(0xFFFFFFFF),
      surfaceContainerLow: const Color(0xFFF2F3F5), // 页面底色（偏灰）
      surfaceContainer: const Color(0xFFEDEEF1),
      surfaceContainerHigh: const Color(0xFFE7E9ED),
      surfaceContainerHighest: const Color(0xFFE1E3E8),
      surface: const Color(0xFFFFFFFF), // 卡片：纯白，浮在灰底上
    );
  }
  return base.copyWith(
    surfaceContainerLowest: const Color(0xFF14161A),
    surfaceContainerLow: const Color(0xFF1B1E24), // 页面底色（更深）
    surfaceContainer: const Color(0xFF22262D),
    surfaceContainerHigh: const Color(0xFF292E36),
    surfaceContainerHighest: const Color(0xFF313741),
    surface: const Color(0xFF262B33), // 卡片：比底色亮一档
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
            colorScheme: _appColorScheme(accent, Brightness.light),
            useMaterial3: true,
            // 全局统一字体（桌面用微软雅黑，移动端系统默认）；
            // 书籍正文由阅读器「字体」设置单独控制
            fontFamily: _uiFont(),
          );
          final darkTheme = ThemeData(
            colorScheme: _appColorScheme(accent, Brightness.dark),
            useMaterial3: true,
            fontFamily: _uiFont(),
          );
          return MaterialApp(
            navigatorKey: AppNavigator.key,
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
