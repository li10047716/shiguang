/// 统一书源接口。
///
/// 规则引擎书源（JSON）与硬编码书源（Dart 模块）都实现此接口，
/// 前端只依赖这里，不区分来源——对应 shiguang 的 `core.book()/chapter()`
/// 按书号前缀分派的思想。
library;

import '../models/book.dart';
import '../models/book_source.dart';
import '../models/content.dart';
import '../models/discover.dart';
import 'novel_source.dart';

abstract class NovelSource {
  /// 书源标识（速读谷=baseUrl；硬编码源如 `qm`、`shuqi`）
  String get sourceId;

  /// 书源显示名
  String get sourceName;

  /// 内容类型（当前仅 novel；旧值仅用于兼容历史数据）
  ContentType get type;

  /// 加载该书源封面/图片时附加的请求头（防盗链 Referer）。
  /// 默认无；书源可按目标图片站要求设置 Referer。
  Map<String, String>? get imageHeaders => null;

  /// 搜索。失败抛 [SourceException]，由聚合层捕获并按源上报。
  Future<List<Book>> search(String keyword, {int page = 1});

  /// 书籍详情（补全简介/封面/最新章节）
  Future<Book> detail(Book book);

  /// 目录加载（支持分页与进度回调）
  Future<TocResult> loadToc(
    Book book, {
    void Function(int page, int count)? onProgress,
    void Function(int pageIndex, List<Chapter> chapters)? onPageChunk,
  });

  /// 小说章节内容（段落文本）
  Future<Content> content(Chapter chapter);

  /// 视频章节的播放地址；非视频源返回 null。
  Future<String?> videoUrl(Chapter chapter) async => null;

  /// 发现页可用标签（空列表 = 该书源不支持发现）。
  List<DiscoverTab> get discoverTabs => const [];

  /// 抓取一页发现内容（榜单 [isRank]=true 用 [key] 作 kind，否则作分类 fc）。
  /// 默认不支持，抛出 [SourceException] 由页面提示。
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) async {
    throw SourceException('$sourceName暂不支持发现');
  }
}

/// 基类：为「不支持发现」的书源提供默认 [discoverTabs]/[discover]。
///
/// 具体书源用 `extends SourceBase`（而非 `implements NovelSource`），
/// 从而继承这两个默认实现，只实现搜索/详情/目录/正文。
abstract class SourceBase implements NovelSource {
  @override
  Map<String, String>? get imageHeaders => null;

  @override
  Future<String?> videoUrl(Chapter chapter) async => null;

  @override
  List<DiscoverTab> get discoverTabs => const [];

  @override
  Future<DiscoverResult> discover(
    String key, {
    bool isRank = true,
    int page = 1,
  }) async {
    throw SourceException('$sourceName暂不支持发现');
  }
}
