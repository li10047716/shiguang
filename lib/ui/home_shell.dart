/// 应用外壳：底部导航（书架 / 发现 / 我的）+ 内容区。
///
/// Material 3 简约风格：全局不透明底色 + 底部导航条，
/// 用 [IndexedStack] 保留各页状态。
library;

import 'package:flutter/material.dart';

import 'discover/discover_page.dart';
import 'glass.dart';
import 'mine/mine_page.dart';
import 'shelf/shelf_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _items = [
    (Icons.library_books_outlined, Icons.library_books, '书架'),
    (Icons.explore_outlined, Icons.explore, '发现'),
    (Icons.person_outline, Icons.person, '我的'),
  ];

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
          // 底部导航条（Material 3 不透明表面，悬浮覆盖在内容之上）
          Positioned(
            left: 0,
            right: 0,
            bottom: 10,
            child: SafeArea(child: Center(child: _bottomNav())),
          ),
        ],
      ),
    );
  }

  Widget _bottomNav() {
    const double itemW = 56; // 每项宽（图标+文字居中）
    final cs = Theme.of(context).colorScheme;
    final activeColor = cs.primary;
    final inactiveColor = cs.onSurfaceVariant;
    return NavGlassBar(
      radius: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Stack(
        children: [
          // 宽胶囊滑动指示器：选中高亮为横向拉长的圆角胶囊，包住整项。
          // AnimatedPositioned 必须直接挂在 Stack 下（ParentDataWidget）。
          AnimatedPositioned(
            duration: const Duration(milliseconds: 340),
            curve: Curves.easeOutBack,
            left: _index * (itemW + 4),
            top: 0,
            bottom: 0,
            width: itemW,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          // 三项按钮（选中高亮由宽胶囊指示器提供）
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _items.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                InkWell(
                  borderRadius: BorderRadius.circular(50),
                  onTap: () => setState(() => _index = i),
                  child: SizedBox(
                    width: itemW,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          i == _index ? _items[i].$2 : _items[i].$1,
                          color: i == _index ? activeColor : inactiveColor,
                          size: 22,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _items[i].$3,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: i == _index
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: i == _index ? activeColor : inactiveColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
