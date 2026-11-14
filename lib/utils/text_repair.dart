/// 乱码检测与修复
///
/// 部分站点会把 UTF-8 字节按 GBK 解读后输出（反爬手段），
/// 表现为大量「銆 / 锛 / 鈥 / 鐨」这类生僻字。
/// 这里做反向还原：GBK 编码回字节 → 按 UTF-8 解码。
/// 站点正常时不会触发，不影响正常内容。
library;

import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';

class TextRepair {
  /// 乱码特征字符（GBK 误解 UTF-8 中文时的典型产物）
  static final _markerRe = RegExp('[銆锛鈥鐨闄鎵澶绗缁闃涓鍦鏄鏈姣璇鍊绔鏂鍚熷彧璇寸殑]');

  /// 是否疑似乱码：特征字符占比超过 3%
  static bool looksMojibake(String text) {
    if (text.length < 40) return false;
    final hits = _markerRe.allMatches(text).length;
    return hits / text.length > 0.03;
  }

  /// 尝试修复；无法确认是乱码时原样返回
  static String repair(String text) {
    if (!looksMojibake(text)) return text;
    final buf = StringBuffer();
    var ok = 0, total = 0;
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) {
        buf.writeln();
        continue;
      }
      total++;
      try {
        final bytes = gbk.encode(line);
        final fixed = utf8.decode(bytes, allowMalformed: true);
        // 修复后若仍大量含乱码特征，说明还原失败，保留原文
        if (looksMojibake(fixed)) {
          buf.writeln(line);
        } else {
          buf.writeln(fixed);
          ok++;
        }
      } catch (_) {
        buf.writeln(line);
      }
    }
    // 多数行修复失败则整体放弃
    return total == 0 || ok / total > 0.5 ? buf.toString().trim() : text;
  }
}
