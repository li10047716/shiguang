/// 视频书源阅读器：一章一个视频地址，支持播放控制与上一集/下一集。
library;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../models/book.dart';
import '../../sources/source_registry.dart';
import '../../sources/novel_source.dart';

class VideoReaderPage extends StatefulWidget {
  const VideoReaderPage({
    super.key,
    required this.book,
    required this.chapters,
    this.initialIndex = 0,
  });

  final Book book;
  final List<Chapter> chapters;
  final int initialIndex;

  @override
  State<VideoReaderPage> createState() => _VideoReaderPageState();
}

class _VideoReaderPageState extends State<VideoReaderPage> {
  late int _index;
  VideoPlayerController? _controller;
  bool _loading = true;
  String? _error;
  bool _showBar = true;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.chapters.length - 1);
    _load();
  }

  Future<void> _load() async {
    await _controller?.dispose();
    _controller = null;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final chapter = widget.chapters[_index];
    try {
      final source = SourceRegistry().byId(widget.book.sourceId);
      if (source == null) throw SourceException('书源不可用');
      final url = await source.videoUrl(chapter);
      if (url == null || url.isEmpty) throw SourceException('未解析到视频地址');
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
      await controller.play();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _go(int delta) async {
    final next = _index + delta;
    if (next < 0 || next >= widget.chapters.length) return;
    setState(() => _index = next);
    await _load();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final chapter = widget.chapters[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: () => setState(() => _showBar = !_showBar),
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '播放失败：$_error',
                        style: const TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : controller != null && controller.value.isInitialized
                  ? AspectRatio(
                      aspectRatio: controller.value.aspectRatio,
                      child: VideoPlayer(controller),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          if (_showBar)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xCC000000), Color(0x00000000)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: SafeArea(
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                      ),
                      Expanded(
                        child: Text(
                          '${widget.book.name} · ${chapter.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      IconButton(
                        onPressed: () => _go(-1),
                        icon: const Icon(
                          Icons.skip_previous,
                          color: Colors.white,
                        ),
                      ),
                      IconButton(
                        onPressed: () => _go(1),
                        icon: const Icon(Icons.skip_next, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_showBar && controller != null && controller.value.isInitialized)
            Positioned(
              left: 12,
              right: 12,
              bottom: 24,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        onPressed: () => controller.value.isPlaying
                            ? controller.pause()
                            : controller.play(),
                        icon: Icon(
                          controller.value.isPlaying
                              ? Icons.pause
                              : Icons.play_arrow,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                    ],
                  ),
                  VideoProgressIndicator(
                    controller,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(
                      playedColor: Colors.greenAccent,
                      bufferedColor: Colors.white54,
                      backgroundColor: Colors.white24,
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
