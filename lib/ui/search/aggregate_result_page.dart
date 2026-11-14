/// 聚合搜索结果页
/// - 顶部进度条：已完成源数 / 总源数
/// - 结果按「书名+作者」聚合，显示来源徽标
/// - 点击展开来源列表（换源），点击具体来源进入详情
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/search_aggregator.dart';
import '../book/book_detail_page.dart';
import '../glass.dart';
import '../widgets/cover_image.dart';
import 'search_page.dart';

class AggregateResultPage extends ConsumerStatefulWidget {
  final String keyword;
  const AggregateResultPage({super.key, required this.keyword});

  @override
  ConsumerState<AggregateResultPage> createState() =>
      _AggregateResultPageState();
}

class _AggregateResultPageState extends ConsumerState<AggregateResultPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(searchAggregatorProvider.notifier).search(widget.keyword);
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(searchAggregatorProvider);
    final total = st.sources.length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(child: GlassBackground()),
          SafeArea(
            child: Column(
              children: [
                // 顶部栏：返回 + 标题 + 重新搜索
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '返回',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '「${st.keyword}」的聚合结果',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit),
                        tooltip: '重新搜索',
                        onPressed: () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(builder: (_) => const SearchPage()),
                        ),
                      ),
                    ],
                  ),
                ),
                // 进度条
                if (st.running)
                  LinearProgressIndicator(
                    value: total == 0 ? null : st.doneCount / total,
                  ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        st.running
                            ? '正在搜索 ${st.doneCount}/$total 个书源…'
                            : '搜索完成：$total 个书源，共 ${st.aggregated.length} 本',
                        style:
                            TextStyle(color: Colors.grey.shade600, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: st.aggregated.isEmpty
                      ? _EmptyOrLoading(running: st.running)
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          itemCount: st.aggregated.length,
                          itemBuilder: (context, i) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _AggregatedTile(
                              item: st.aggregated[i],
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyOrLoading extends StatelessWidget {
  final bool running;
  const _EmptyOrLoading({required this.running});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: running
          ? const CircularProgressIndicator()
          : Glass(
              radius: 16,
              padding: const EdgeInsets.symmetric(
                  horizontal: 24, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.search_off, size: 56, color: Colors.grey),
                  const SizedBox(height: 12),
                  const Text('没有搜到结果'),
                  const SizedBox(height: 8),
                  Text('提示：换一个关键词试试；也可到书架页的\n「书源管理」中启用或导入更多书源',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 12)),
                ],
              ),
            ),
    );
  }
}

class _AggregatedTile extends StatefulWidget {
  final AggregatedBook item;
  const _AggregatedTile({required this.item});

  @override
  State<_AggregatedTile> createState() => _AggregatedTileState();
}

class _AggregatedTileState extends State<_AggregatedTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Glass(
      radius: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: SizedBox(
              width: 44,
              height: 58,
              child: item.cover.isEmpty
                  ? Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.menu_book, color: Colors.grey),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CoverImage(item.cover,
                          sourceId: item.coverSourceId),
                    ),
            ),
            title: Text(item.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              item.author.isEmpty ? '佚名' : item.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF3E8EF7).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${item.sourceCount} 源',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF3E8EF7),
                ),
              ),
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            ...item.fromSources.map(
              (b) => Padding(
                padding: const EdgeInsets.only(left: 60, right: 8, bottom: 8),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.source_outlined, size: 18),
                  title: Text(b.sourceName,
                      style: const TextStyle(fontSize: 13)),
                  trailing: b.lastChapter == null
                      ? null
                      : Text('更新: ${b.lastChapter}',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade500)),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => BookDetailPage(book: b),
                  )),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
