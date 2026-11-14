/// 应用外壳：底部玻璃导航（书架 / 发现 / 我的）+ 内容区。
///
/// iOS 液态玻璃风格：全局渐变底 + 底部悬浮毛玻璃导航条，
/// 内容页用透明 Scaffold 透出背景。用 [IndexedStack] 保留各页状态。
library;

import 'dart:ui';

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

  static const _activeColor = Color(0xFF2E7D5B);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: GlassBackground()),
          // 内容区：顶部/底部避让系统安全区（iPhone 刘海/Home 条），
          // 底部再留出悬浮导航条高度，避免内容被遮挡
          Padding(
            padding: const EdgeInsets.only(bottom: 74),
            child: SafeArea(
              child: IndexedStack(
                index: _index,
                children: const [
                  ShelfPage(),
                  DiscoverPage(),
                  MinePage(),
                ],
              ),
            ),
          ),
          // 底部悬浮毛玻璃导航条（iOS 液态玻璃，只包裹三个按钮并居中）
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
    final inactiveColor = Colors.grey.shade600;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            color: Colors.white.withValues(alpha: 0.55),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min, // 只包裹三个按钮
              children: [
                for (var i = 0; i < _items.length; i++)
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => setState(() => _index = i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                          vertical: 5, horizontal: 16),
                      decoration: BoxDecoration(
                        color: i == _index
                            ? _activeColor.withValues(alpha: 0.14)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            i == _index ? _items[i].$2 : _items[i].$1,
                            color: i == _index ? _activeColor : inactiveColor,
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
                              color:
                                  i == _index ? _activeColor : inactiveColor,
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
      ),
    );
  }
}
