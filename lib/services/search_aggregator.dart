/// 聚合搜索服务：并发调用多个书源，先到先推流，按书名+作者归一化合并。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/book.dart';
import '../sources/source.dart';
import '../sources/source_registry.dart';

/// 单个源的搜索状态
enum SourceState { pending, running, done, failed }

class SourceResult {
  final NovelSource source;
  final SourceState state;
  final List<Book> books;
  final String? error;

  const SourceResult({
    required this.source,
    required this.state,
    this.books = const [],
    this.error,
  });
}

/// 聚合搜索的整体进度快照
class AggregateSearchState {
  final String keyword;
  final bool running;
  final List<SourceResult> sources; // 每源状态
  final List<AggregatedBook> aggregated; // 合并后的书籍（按来源数排序）

  const AggregateSearchState({
    this.keyword = '',
    this.running = false,
    this.sources = const [],
    this.aggregated = const [],
  });

  int get doneCount =>
      sources.where((s) => s.state == SourceState.done || s.state == SourceState.failed).length;

  AggregateSearchState copyWith({
    String? keyword,
    bool? running,
    List<SourceResult>? sources,
    List<AggregatedBook>? aggregated,
  }) =>
      AggregateSearchState(
        keyword: keyword ?? this.keyword,
        running: running ?? this.running,
        sources: sources ?? this.sources,
        aggregated: aggregated ?? this.aggregated,
      );
}

/// 一本聚合书：同名同作者的多源结果合并
class AggregatedBook {
  final String name;
  final String author;
  final String cover;
  final List<Book> fromSources; // 各来源结果，可换源

  AggregatedBook({
    required this.name,
    required this.author,
    required this.cover,
    required this.fromSources,
  });

  int get sourceCount => fromSources.length;

  /// 封面归属的书源 id（用于防盗链头）。
  /// 取第一个带该封面的来源；没有则退回首个来源。
  String? get coverSourceId {
    for (final b in fromSources) {
      if (b.cover == cover && b.sourceId.isNotEmpty) return b.sourceId;
    }
    return fromSources.isEmpty ? null : fromSources.first.sourceId;
  }
}

class SearchAggregator extends StateNotifier<AggregateSearchState> {
  static const _perSourceTimeout = Duration(seconds: 12);
  static const _maxConcurrency = 6;

  SearchAggregator() : super(const AggregateSearchState());

  /// 启动一次聚合搜索（全部启用书源，小说 + 漫画）
  void search(String keyword) {
    final sources = SourceRegistry().enabled;
    state = AggregateSearchState(
      keyword: keyword,
      running: true,
      sources: sources
          .map((s) => SourceResult(source: s, state: SourceState.pending))
          .toList(),
      aggregated: const [],
    );

    // 用一个共享的可合并结果集，按源完成顺序增量更新
    final merged = <String, List<Book>>{}; // normalizeKey -> books
    var index = 0;

    void patch(int i, SourceResult r) {
      final list = [...state.sources];
      list[i] = r;
      // 重建聚合列表（来源多的在前）
      final agg = merged.entries
          .map((e) {
            final books = e.value;
            return AggregatedBook(
              name: books.first.name,
              author: books.first.author,
              cover: _pickCover(books),
              fromSources: books,
            );
          })
          .toList()
        ..sort((a, b) => b.sourceCount.compareTo(a.sourceCount));
      state = state.copyWith(sources: list, aggregated: agg);
    }

    Future<void> runOne(NovelSource src, int i) async {
      try {
        final books = await src.search(keyword).timeout(_perSourceTimeout);
        // 增量合并
        for (final b in books) {
          merged.putIfAbsent(b.normalizeKey, () => []).add(b);
        }
        patch(i, SourceResult(source: src, state: SourceState.done, books: books));
      } catch (e) {
        patch(i, SourceResult(source: src, state: SourceState.failed, error: e.toString()));
      }
    }

    // 简单并发控制：每批 maxConcurrency 个
    Future<void> runAll() async {
      while (index < sources.length) {
        final batch = <Future>[];
        while (batch.length < _maxConcurrency && index < sources.length) {
          final i = index++;
          batch.add(runOne(sources[i], i));
        }
        await Future.wait(batch);
      }
      state = state.copyWith(running: false);
    }

    runAll();
  }

  static String _pickCover(List<Book> books) {
    for (final b in books) {
      if (b.cover.isNotEmpty) return b.cover;
    }
    return '';
  }
}

/// 全局 provider
final searchAggregatorProvider =
    StateNotifierProvider<SearchAggregator, AggregateSearchState>(
        (ref) => SearchAggregator());
