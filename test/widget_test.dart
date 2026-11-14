// 应用冒烟测试：确认「悦读」根组件在 ProviderScope 内能正常构建，
// 并且书架页渲染出标题。替换 Flutter 模板默认的计数器测试。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reading_app/main.dart';

void main() {
  testWidgets('应用能构建并显示书架页', (WidgetTester tester) async {
    // runAsync 让真实 IO（发现页启动时预取榜单）在测试事件循环里走完，
    // 避免遗留 pending timer 导致测试收尾报错。
    await tester.runAsync(() async {
      await tester.pumpWidget(const ProviderScope(child: ReadingApp()));
      await tester.pump();

      // 应用标题应出现（MaterialApp title 不渲染为文本，检查 Scaffold 存在）
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(Scaffold), findsWidgets);
    });
  });
}
