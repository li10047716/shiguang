/// 内容类型小标签：小说（红）/ 漫画（紫）/ 视频（青绿）。
library;

import 'package:flutter/material.dart';

import '../../models/book_source.dart';

class TypeTag extends StatelessWidget {
  final ContentType type;
  const TypeTag({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (type) {
      ContentType.comic => ('漫画', const Color(0xFF7C6FF0)),
      ContentType.video => ('视频', const Color(0xFF12A594)),
      ContentType.novel => ('小说', const Color(0xFFE5484D)),
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
            color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
  }
}
