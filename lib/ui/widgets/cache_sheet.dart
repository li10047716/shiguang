/// 缓存管理面板（阅读器 / 书详情共用）。
///
/// 显示本书已缓存章节数，支持缓存全书、缓存后续、取消、清除本书缓存。
/// 下载统一走 [CacheDownload]，因此取消对阅读器/书详情/全局管理页都生效。
library;

import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../services/cache_download.dart';
import '../../services/chapter_cache.dart';
import '../../sources/source_registry.dart';

class CacheSheet extends StatefulWidget {
  final Book book;
  final List<Chapter> Function() chapters;
  final int total;
  final int currentIndex;

  const CacheSheet({
    super.key,
    required this.book,
    required this.chapters,
    required this.total,
    required this.currentIndex,
  });

  @override
  State<CacheSheet> createState() => _CacheSheetState();
}

class _CacheSheetState extends State<CacheSheet> {
  int _cached = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final n = await ChapterCache.bookCount(widget.book.bookUrl);
    if (mounted) setState(() => _cached = n);
  }

  Future<void> _start({required int from}) async {
    final source = SourceRegistry().byId(widget.book.sourceId);
    if (source == null) {
      _tip('书源不可用');
      return;
    }
    final chapters = widget.chapters();
    if (from >= chapters.length) {
      _tip('没有可缓存的章节');
      return;
    }
    setState(() => _busy = true);
    await CacheDownload.instance.start(
      book: widget.book,
      source: source,
      chapters: chapters,
      fromIndex: from,
      onDone: (done, failed, cancelled) {
        if (!mounted) return;
        setState(() => _busy = false);
        _refresh();
        _tip(cancelled
            ? '已停止，缓存 $done 章'
            : '缓存完成：$done 章${failed > 0 ? '（$failed 章失败）' : ''}');
      },
    );
  }

  Future<void> _clear() async {
    final n = await ChapterCache.clearBook(widget.book.bookUrl);
    if (!mounted) return;
    _refresh();
    _tip('已清除 $n 章缓存');
  }

  void _tip(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = widget.total;
    return ValueListenableBuilder<Map<String, DownloadTask>>(
      valueListenable: CacheDownload.instance.tasks,
      builder: (_, tasks, _) {
        final task = tasks[widget.book.bookUrl];
        final running = task != null;
        return Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 12,
            bottom: MediaQuery.of(context).padding.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Icon(Icons.download_for_offline_outlined, size: 20),
                  const SizedBox(width: 8),
                  Text('缓存管理',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('${widget.book.name}　已缓存 $_cached / 共 $total 章',
                  style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: total == 0 ? 0 : _cached / total,
                minHeight: 6,
              ),
              if (running) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(value: task.progress),
                    ),
                    const SizedBox(width: 10),
                    Text('${task.done}/${task.total}',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                  ],
                ),
                const SizedBox(height: 6),
                Text('失败 ${task.failed} 章',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ],
              const SizedBox(height: 20),
              if (running)
                OutlinedButton.icon(
                  onPressed: () =>
                      CacheDownload.instance.cancel(widget.book.bookUrl),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('取消缓存'),
                )
              else ...[
                FilledButton.icon(
                  onPressed: _busy ? null : () => _start(from: 0),
                  icon: const Icon(Icons.download_done_outlined),
                  label: const Text('缓存全书'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _busy || total <= widget.currentIndex + 1
                      ? null
                      : () => _start(from: widget.currentIndex + 1),
                  icon: const Icon(Icons.download),
                  label: const Text('仅缓存后续章节'),
                ),
              ],
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: _cached == 0 || running ? null : _clear,
                icon: Icon(Icons.delete_outline, color: cs.error, size: 18),
                label: Text('清除本书缓存（$_cached 章）',
                    style: TextStyle(color: cs.error, fontSize: 13)),
              ),
            ],
          ),
        );
      },
    );
  }
}
