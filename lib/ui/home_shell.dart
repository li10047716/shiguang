/// 应用外壳：底部导航（书架 / 发现 / 我的）+ 内容区。
///
/// Material 3 简约风格：全局不透明底色 + 底部导航条，
/// 用 [IndexedStack] 保留各页状态。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/update_checker.dart';
import 'discover/discover_page.dart';
import 'glass.dart';
import 'mine/mine_page.dart';
import 'shelf/shelf_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  // 定时检查更新：冷启动查一次 + 每次从后台回前台查一次。
  // 用时间戳去重，避免启动瞬间 resumed 与 initState 重复触发。
  DateTime? _lastAutoCheck;
  Timer? _startupTimer;

  static const _items = [
    (Icons.library_books_outlined, Icons.library_books, '书架'),
    (Icons.explore_outlined, Icons.explore, '发现'),
    (Icons.person_outline, Icons.person, '我的'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 冷启动：等书架数据加载完成后检查一次
    _startupTimer = Timer(const Duration(seconds: 2), _autoCheckUpdates);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _startupTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _autoCheckUpdates();
  }

  /// 定时检查书架更新：仅检查 + 应用内 SnackBar 提示。
  /// 检查逻辑与书架下拉刷新共用 [UpdateChecker]，基线计数共享。
  Future<void> _autoCheckUpdates() async {
    // 每本书的更新开关在 UpdateChecker.check() 内部过滤（默认全开）。
    final now = DateTime.now();
    if (_lastAutoCheck != null &&
        now.difference(_lastAutoCheck!) < const Duration(seconds: 20)) {
      return;
    }
    _lastAutoCheck = now;
    final n = await UpdateChecker.check();
    if (n > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$n 本书有更新'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: AppBackground()),
          // 内容区：让内容延伸到屏幕底（悬浮导航条覆盖其上并模糊），
          // 避免内容下缘到屏幕底之间露出裸渐变「遮罩带」。
          // 各页（书架/发现/我的）自带 SafeArea 处理刘海/Home 条。
          SafeArea(
            child: IndexedStack(
              index: _index,
              children: const [
                ShelfPage(),
                DiscoverPage(),
                MinePage(),
              ],
            ),
          ),
          // 底部通栏固定条：与阅读器控制栏同款——铺满宽度、贴底、纯色背景 + 顶部分隔线
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _bottomNav(),
          ),
        ],
      ),
    );
  }

  Widget _bottomNav() {
    const double itemW = 72; // 每项宽（图标+文字居中）
    final cs = Theme.of(context).colorScheme;
    final activeColor = cs.primary;
    final inactiveColor = cs.onSurfaceVariant;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        // 顶边细线：区分正文与底部固定栏；完全直角贴底铺满
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < _items.length; i++)
                InkWell(
                  onTap: () => setState(() => _index = i),
                  child: SizedBox(
                    width: itemW,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          i == _index ? _items[i].$2 : _items[i].$1,
                          color: i == _index ? activeColor : inactiveColor,
                          size: 22,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _items[i].$3,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: i == _index
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: i == _index
                                ? activeColor
                                : inactiveColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
