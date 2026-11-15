/// 阅读偏好共享常量：阅读器内设置弹窗 / 我的页「阅读设置」页共用。
///
/// 背景主题顺序保持前 4 个不变（0 米黄 / 1 素白 / 2 淡绿 / 3 夜间），
/// 兼容旧版本已存的 reader_bg 索引，新主题追加在后。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class ReaderPrefs {
  ReaderPrefs._();

  static const bgNames = [
    '米黄',
    '素白',
    '淡绿',
    '夜间',
    '羊皮纸',
    '淡蓝',
    '青灰',
    '纯黑',
  ];

  static const bgOptions = [
    Colors.white, // 素白
    Color(0xFFE3F2E7), // 淡绿
    Color(0xFF2B2B2B), // 夜间
    Color(0xFFEFE3CE), // 羊皮纸
  ];

  /// 暗色主题（夜间 / 纯黑）：控制栏用更低不透明度
  static bool isDark(Color bg) => bg.computeLuminance() < 0.15;

  /// 字体：仅系统默认（字体切换已移除，固定系统字体）。
  /// 索引对应 [fontFamilies]，0 = 系统默认。
  static const fontNames = ['系统默认'];
  static const _winFonts = <String?>[null];
  static const _iosFonts = <String?>[null];
  static List<String?> get fontFamilies =>
      defaultTargetPlatform == TargetPlatform.windows ? _winFonts : _iosFonts;

  /// 翻页效果：0 左右平移 / 1 上下平移 / 2 上下滑动 / 3 仿真翻页
  static const turnNames = ['左右平移', '上下平移', '上下滑动', '仿真翻页'];

  /// 背景壁纸（渐变）。索引 0 = 无（用纯色纸色），其余为渐变色。
  static const wallpaperNames = ['无', '晨曦', '森林', '海洋', '黄昏', '星夜'];
  static const wallpapers = <List<Color>>[
    [], // 无
    [Color(0xFFFFE9C7), Color(0xFFFFD1E8), Color(0xFFE3D6FF)], // 晨曦
    [Color(0xFFD6F2E0), Color(0xFFBDE7E9), Color(0xFFC9EFC7)], // 森林
    [Color(0xFFD6E9FF), Color(0xFFC9D8FF), Color(0xFFD6F4FF)], // 海洋
    [Color(0xFFFFD9C4), Color(0xFFFFB3A5), Color(0xFFFFE0B2)], // 黄昏
    [Color(0xFF3A3F63), Color(0xFF4A4A7A), Color(0xFF2E3A59)], // 星夜
  ];
}
