/// 发现页数据模型：榜单/分类标签 + 一页结果。
library;

import 'book.dart';

/// 一个发现标签（榜单类型或书库分类）。
class DiscoverTab {
  final String key; // kind（榜单）或 fc（分类）
  final String name;
  final bool isRank; // true=榜单 tab，false=分类 tab

  const DiscoverTab({
    required this.key,
    required this.name,
    required this.isRank,
  });

  // 选中态比较用值语义：书源刷新后 discoverTabs 会重建对象，
  // 仅靠引用相等会导致已选标签失去高亮。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoverTab &&
          other.key == key &&
          other.isRank == isRank &&
          other.name == name;

  @override
  int get hashCode => Object.hash(key, isRank, name);
}

/// 一页发现内容（某榜单/分类的第 page 页）。
class DiscoverResult {
  final String title;
  final List<Book> books;
  final int page;
  final int pages;

  const DiscoverResult({
    required this.title,
    required this.books,
    this.page = 1,
    this.pages = 1,
  });
}
