/// 全局外观控制：强调色 + 深色模式。
///
/// 用静态 [ValueNotifier] 让设置页改值即触发 MaterialApp 重建（主题实时生效）。
library;

import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  /// 当前强调色（seed），默认蓝
  static final ValueNotifier<Color> accent =
      ValueNotifier(const Color(0xFF3E8EF7));

  /// 深色模式：0 跟随系统 / 1 浅色 / 2 深色
  static final ValueNotifier<int> darkMode = ValueNotifier(0);

  static const accents = [
    Color(0xFF3E8EF7), // 蓝
    Color(0xFF2E7D5B), // 绿
    Color(0xFF7C6FF0), // 紫
    Color(0xFFE58B3A), // 橙
    Color(0xFFE5484D), // 红
  ];
  static const accentNames = ['蓝', '绿', '紫', '橙', '红'];

  static ThemeMode get themeMode => switch (darkMode.value) {
        1 => ThemeMode.light,
        2 => ThemeMode.dark,
        _ => ThemeMode.system,
      };
}
