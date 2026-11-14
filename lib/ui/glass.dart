/// iOS 液态玻璃（liquid glass）风格的通用组件。
///
/// - [GlassBackground]：全屏柔和渐变底（玻璃需要背景可透）。
/// - [Glass]：半透明白玻璃容器 + 高光描边 + 圆角，可选背景模糊。
///   大量卡片用 `blur: 0`（仅半透明填充，省性能，透出渐变已有玻璃感）；
///   常驻 chrome（侧栏/顶栏/胶囊）用 `blur: ~18` 出真实毛玻璃。
library;

import 'dart:ui';

import 'package:flutter/material.dart';

/// 全屏柔和渐变背景（浅蓝 → 淡紫 → 薄荷）。
class GlassBackground extends StatelessWidget {
  final Widget? child;
  const GlassBackground({super.key, this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF1E2330), Color(0xFF2A2233), Color(0xFF1E2B26)]
              : const [Color(0xFFD9E8FF), Color(0xFFE9E3FF), Color(0xFFD8F2E6)],
        ),
      ),
      child: child ?? const SizedBox.expand(),
    );
  }
}

/// 居中玻璃弹窗容器。
///
/// `showDialog` 的 builder 若直接返回 [Glass]，会因路由页收到全屏紧约束而
/// 铺满整个窗口。用 [Center] 松绑 + [ConstrainedBox] 限宽，得到居中弹窗。
class GlassDialog extends StatelessWidget {
  final Widget child;
  final double minWidth;
  final double maxWidth;

  const GlassDialog({
    super.key,
    required this.child,
    this.minWidth = 340,
    this.maxWidth = 420,
  });

  @override
  Widget build(BuildContext context) {
    // 手机屏较窄时（如 320/375 逻辑像素），固定宽度会溢出；
    // 按屏宽 clamp，两侧留 16 边距。
    final sw = MediaQuery.of(context).size.width;
    final mw = maxWidth.clamp(0.0, sw - 32);
    final mn = minWidth > mw ? mw : minWidth;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: mn, maxWidth: mw),
        child: child,
      ),
    );
  }
}

/// 液态玻璃容器。
class Glass extends StatelessWidget {
  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final double tintOpacity;
  final Border? border;

  const Glass({
    super.key,
    required this.child,
    this.radius = 16,
    this.blur = 0,
    this.padding,
    this.tintOpacity = 0.42,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final fill = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: tintOpacity),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );

    Widget inner = fill;
    if (blur > 0) {
      inner = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: fill,
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: border ??
            Border.all(color: Colors.white.withValues(alpha: 0.55), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: inner,
    );
  }
}
