/// 应用外壳：底部玻璃导航（书架 / 发现 / 我的）+ 内容区。
///
/// iOS 液态玻璃风格：全局渐变底 + 底部悬浮毛玻璃导航条，
/// 内容页用透明 Scaffold 透出背景。用 [IndexedStack] 保留各页状态。
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
    const double itemW = 56; // 每项宽（图标+文字居中）
    final inactiveColor = Colors.grey.shade600;
    // 液态玻璃椭圆胶囊：包住三个导航按钮
    return Glass(
      radius: 24,
      blur: 18,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Stack(
        children: [
          // 液态滑动指示器：选中高亮像液体一样弹性滑到新选中项。
          // 注意：AnimatedPositioned 必须直接挂在 Stack 下（ParentDataWidget），
          // 不能再用 IgnorePointer 等包裹，否则 applyParentData 强转 StackParentData 失败。
          AnimatedPositioned(
            duration: const Duration(milliseconds: 340),
            curve: Curves.easeOutBack,
            left: _index * (itemW + 4),
            top: 4,
            bottom: 4,
            width: itemW,
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: _activeColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          // 三项按钮（内容居中；选中高亮由滑动指示器提供）
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < _items.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _index = i),
                  child: SizedBox(
                    width: itemW,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
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
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
