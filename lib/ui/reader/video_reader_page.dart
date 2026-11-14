/// 视频阅读器：播放视频书源（m3u8/mp4），自动连播下一集。
library;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../models/book.dart';
import '../../sources/source_registry.dart';

class VideoReaderPage extends StatefulWidget {
  final Book book;
  final List<Chapter> chapters;
  final int initialIndex;

  const VideoReaderPage({
    super.key,
    required this.book,
    required this.chapters,
    this.initialIndex = 0,
  });

  @override
  State<VideoReaderPage> createState() => _VideoReaderPageState();
}

class _VideoReaderPageState extends State<VideoReaderPage> {
  late final Player _player;
  late final VideoController _controller;
  late int _index;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.chapters.length - 1);
    _player = Player();
    _controller = VideoController(_player);
    // 播完自动连播下一集
    _player.stream.completed.listen((_) {
      if (mounted && _index < widget.chapters.length - 1) {
        _play(_index + 1);
      }
    });
    _play(_index);
  }

  Future<void> _play(int i) async {
    if (i < 0 || i >= widget.chapters.length) return;
    setState(() {
      _index = i;
      _loading = true;
      _error = null;
    });
    try {
      final source = SourceRegistry().byId(widget.book.sourceId);
      if (source == null) throw Exception('找不到书源');
      final c = await source.content(widget.chapters[i]);
      if (c.video.isEmpty) throw Exception('无视频地址');
      await _player.open(Media(c.video));
      await _player.play();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  void _next() => _play(_index + 1);
  void _prev() => _play(_index - 1);

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 播放区
          Positioned.fill(
            child: _loading && _error == null
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.white))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                      )
                    : Video(controller: _controller),
          ),
          // 顶部返回
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: IconButton(
                tooltip: '返回',
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          // 底部：上一集 | 第N集/共M集 | 下一集
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Container(
                color: Colors.black.withValues(alpha: 0.55),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '上一集',
                      icon: const Icon(Icons.skip_previous,
                          color: Colors.white),
                      onPressed: _index > 0 ? _prev : null,
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          '第${_index + 1}集 / 共${widget.chapters.length}集',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '下一集',
                      icon: const Icon(Icons.skip_next, color: Colors.white),
                      onPressed: _index < widget.chapters.length - 1
                          ? _next
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
