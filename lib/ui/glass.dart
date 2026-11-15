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

/// 玻璃圆钮：白 0.16 填充 + 毛玻璃 blur 3 + 高光描边 + 软投影。
/// 与阅读器控制栏圆钮同款，供各页顶部图标按钮统一使用。
class GlassRoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final double iconSize;

  /// 关闭投影（顶栏悬浮元素直接贴在背景上，避免出现额外暗层）。
  final bool shadow;

  const GlassRoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
    this.iconSize = 20,
    this.shadow = true,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.4), width: 1),
            boxShadow: shadow
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 9,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : const [],
          ),
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.28),
                ),
                child: Icon(icon,
                    size: iconSize, color: color ?? Colors.grey.shade800),
              ),
            ),
          ),
        ),
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

  /// 关闭投影（顶栏悬浮元素直接贴在背景上，避免出现额外暗层）。
  final bool shadow;

  const Glass({
    super.key,
    required this.child,
    this.radius = 16,
    this.blur = 0,
    this.padding,
    this.tintOpacity = 0.28,
    this.border,
    this.shadow = true,
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
            Border.all(color: Colors.white.withValues(alpha: 0.35), width: 1),
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 9,
                  offset: const Offset(0, 4),
                ),
              ]
            : const [],
      ),
      child: inner,
    );
  }
}
