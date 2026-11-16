/// Material 3 简约风格的通用组件。
///
/// - [GlassBackground]：全屏不透明底色（跟随主题 surfaceContainerLow）。
/// - [Glass]：不透明 surface 卡片 + 淡描边 + 轻投影（Material 3 Card）。
/// - [GlassRoundButton]：不透明 surface 圆形图标按钮。
/// - [GlassDialog]：居中弹窗约束容器。
///
/// 说明：原为 iOS 液态玻璃风格（半透明 + 背景模糊 + 高光描边），现整体改为
/// Material 3。为兼容所有调用点，保留了原有类名与参数（blur / tintOpacity
/// 仅保留签名，不再产生毛玻璃或半透明效果）。
library;

import 'package:flutter/material.dart';

/// 全屏不透明底色（Material 3 surfaceContainerLow）。
class GlassBackground extends StatelessWidget {
  final Widget? child;
  const GlassBackground({super.key, this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.surfaceContainerLow,
      child: child ?? const SizedBox.expand(),
    );
  }
}

/// 居中弹窗容器。
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

/// Material 3 圆形图标按钮：不透明 surface 填充 + 淡描边 + 轻投影。
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
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cs.surface,
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.6), width: 1),
            boxShadow: shadow
                ? [
                    BoxShadow(
                      color: cs.shadow.withValues(alpha: 0.12),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : const [],
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon,
                size: iconSize, color: color ?? cs.onSurface),
          ),
        ),
      ),
    );
  }
}

/// Material 3 卡片容器：不透明 surface + 淡描边 + 轻投影。
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
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(radius),
        border: border ??
            Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.6), width: 1),
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: cs.shadow.withValues(alpha: 0.12),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : const [],
      ),
      child: child,
    );
  }
}
