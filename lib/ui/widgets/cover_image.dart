/// 带防盗链头的网络封面/图片组件。
///
/// 封面 CDN（如大人漫画 p4p.18rouman.vip）对「无 Referer 请求」会**截断响应**
/// （RIFF 声明全图大小但只吐前几百字节），`Image.network` 不带任何头，
/// 解码必然失败 → 灰块。这里改用 [HttpClient.getBytes]（全局 UA + 书源
/// 自己的 Referer），并在内存缓存字节，多卡片复用同一 Future。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/http_client.dart';
import '../../sources/source_registry.dart';

/// 按书源 id 解析图片防盗链请求头（[NovelSource.imageHeaders]）。
Map<String, String>? imageHeadersFor(String? sourceId) {
  if (sourceId == null || sourceId.isEmpty) return null;
  return SourceRegistry().byId(sourceId)?.imageHeaders;
}

/// 带书源头的网络封面。空 URL 显示占位图。
class CoverImage extends StatefulWidget {
  final String url;
  final String? sourceId;

  /// 直接指定头（优先级高于 [sourceId] 解析）。
  final Map<String, String>? headers;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// 是否缓存字节（封面小图缓存；漫画整页大图不缓存，避免内存膨胀）。
  final bool cache;

  /// 加载中占位（默认灰块+图标）；传 [loadingWidget] 可自定义（如进度圈）。
  final Widget? loadingWidget;

  const CoverImage(
    this.url, {
    super.key,
    this.sourceId,
    this.headers,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cache = true,
    this.loadingWidget,
  });

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  static final Map<String, Future<Uint8List>> _cache = {};

  // 解码失败重试次数（CDN 偶发截断 → 解码失败 → 重新拉一次）
  int _attempt = 0;

  Future<Uint8List> _load() {
    final headers = widget.headers ?? imageHeadersFor(widget.sourceId);
    if (!widget.cache) {
      return HttpClient.getBytes(widget.url, headers: headers)
          .then(Uint8List.fromList);
    }
    final key = '${widget.url}|$_attempt';
    return _cache.putIfAbsent(key, () async {
      // 磁盘缓存命中：重进 app 后封面秒开（CDN 慢，首次才走网络）
      if (_attempt == 0) {
        final disk = await _readDisk(widget.url);
        if (disk != null) return disk;
      }
      try {
        final bytes =
            await HttpClient.getBytes(widget.url, headers: headers);
        final u8 = Uint8List.fromList(bytes);
        if (_attempt == 0) _writeDisk(widget.url, u8); // 后台落盘
        return u8;
      } catch (_) {
        _cache.remove(key); // 失败不缓存，下次可重试
        rethrow;
      }
    });
  }

  // ---------- 封面磁盘缓存（首次慢 CDN，重访秒开）----------

  static Future<File?> _diskFile(String url) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final sub = Directory('${dir.path}/cover_cache');
      if (!await sub.exists()) await sub.create(recursive: true);
      return File('${sub.path}/${_hash(url)}.img');
    } catch (_) {
      return null; // 测试环境无平台通道，跳过磁盘
    }
  }

  static Future<Uint8List?> _readDisk(String url) async {
    try {
      final f = await _diskFile(url);
      if (f == null || !await f.exists()) return null;
      final bytes = await f.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  static void _writeDisk(String url, Uint8List bytes) {
    _diskFile(url).then((f) {
      if (f != null) f.writeAsBytes(bytes);
    }).catchError((_) {});
  }

  /// 稳定字符串 hash（不依赖 crypto，跨进程一致，仅用于文件名）。
  static String _hash(String s) {
    var h = 7;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h.toRadixString(16);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.url.isEmpty) return _staticPlaceholder(icon: Icons.menu_book);
    return FutureBuilder<Uint8List>(
      future: _load(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          // 加载中：骨架屏（脉动占位）
          return widget.loadingWidget ?? _SkeletonBox(
            width: widget.width,
            height: widget.height,
          );
        }
        if (snap.hasError) {
          return _staticPlaceholder(icon: Icons.broken_image);
        }
        return Image.memory(
          snap.data!,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          gaplessPlayback: true,
          // 图片淡入（300ms），避免生硬弹入
          frameBuilder: (context, child, frame, wasSync) {
            if (wasSync) return child;
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: child,
            );
          },
          errorBuilder: (_, _, _) {
            // 字节截断导致解码失败：清缓存，重试一次
            if (_attempt == 0) {
              _cache.remove('${widget.url}|0');
              setState(() => _attempt = 1);
              return widget.loadingWidget ??
                  _SkeletonBox(
                    width: widget.width,
                    height: widget.height,
                  );
            }
            return _staticPlaceholder(icon: Icons.broken_image);
          },
        );
      },
    );
  }

  Widget _staticPlaceholder({IconData icon = Icons.image_outlined}) {
    return Container(
      width: widget.width,
      height: widget.height,
      color: Colors.grey.shade200,
      alignment: Alignment.center,
      child: Icon(icon, size: 28, color: Colors.grey),
    );
  }
}

/// 骨架屏：脉动浅灰占位块（封面加载中显示，替代静态灰块）。
class _SkeletonBox extends StatefulWidget {
  final double? width;
  final double? height;
  const _SkeletonBox({this.width, this.height});

  @override
  State<_SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<_SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Container(
        width: widget.width,
        height: widget.height,
        color: Color.lerp(
          const Color(0xFFE3E3E8),
          const Color(0xFFF3F3F6),
          _c.value,
        ),
      ),
    );
  }
}
