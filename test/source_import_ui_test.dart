import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reading_app/sources/builtin/builtin_sources.dart';
import 'package:reading_app/sources/source_registry.dart';
import 'package:reading_app/ui/mine/mine_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 页面含循环转圈动画时 pumpAndSettle 永远超时，改用固定帧推进。
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  testWidgets('导入按钮位于拖拽列表外，取消不落盘，确认后新增和覆盖有报告', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: MinePage())),
    );
    await settle(tester);
    await tester.tap(find.text('书源管理'));
    await settle(tester);
    await SourceRegistry().ready;
    await settle(tester);
    for (final label in ['文件 JSON/JS', 'URL 下载', '粘贴 JSON/JS']) {
      expect(find.text(label), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(ReorderableListView),
        ),
        findsNothing,
      );
    }
    final json =
        (jsonDecode(builtinSourcesJson) as List).first as Map<String, dynamic>;
    json['sourceUrl'] = 'https://ui-import.test';
    json['sourceName'] = '界面测试书源';
    final repo = SourceRepository();
    final sp = await SharedPreferences.getInstance();
    final before = sp.getStringList('custom_sources');

    Future<void> preview() async {
      await tester.tap(find.text('粘贴 JSON/JS'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), jsonEncode(json));
      await tester.tap(find.text('解析'));
      await settle(tester);
    }

    await preview();
    expect(find.text('导入确认（同 URL 将被覆盖）'), findsOneWidget);
    expect(repo.byId('https://ui-import.test'), isNull);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(sp.getStringList('custom_sources'), before);

    await preview();
    await tester.tap(find.text('确认导入并覆盖以上同 URL 书源'));
    await settle(tester);
    expect(find.text('新增 1，覆盖 0，跳过 0'), findsOneWidget);
    expect(repo.byId('https://ui-import.test')!.name, '界面测试书源');
    await tester.tap(find.text('关闭'));
    await settle(tester);

    json['sourceName'] = '界面覆盖书源';
    await preview();
    expect(find.textContaining('预计新增 0，覆盖 1'), findsOneWidget);
    expect(repo.byId('https://ui-import.test')!.name, '界面测试书源');
    await tester.tap(find.text('确认导入并覆盖以上同 URL 书源'));
    await settle(tester);
    expect(find.text('新增 0，覆盖 1，跳过 0'), findsOneWidget);
    expect(repo.byId('https://ui-import.test')!.name, '界面覆盖书源');
    expect(tester.takeException(), isNull);
  });
}
