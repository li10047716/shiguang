/// 小说书源标签。
library;

import 'package:flutter/material.dart';

import '../../models/book_source.dart';

/// 内容类型角标：小说（红）/ 漫画（蓝）/ 视频（紫）。默认小说。
class TypeTag extends StatelessWidget {
  final ContentType type;
  const TypeTag({super.key, this.type = ContentType.novel});

  @override
  Widget build(BuildContext context) {
    final color = switch (type) {
      ContentType.comic => const Color(0xFF3E8EF7),
      ContentType.video => const Color(0xFF8E5CE6),
      _ => const Color(0xFFE5484D),
    };
    final label = switch (type) {
      ContentType.comic => '漫画',
      ContentType.video => '视频',
      _ => '小说',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
