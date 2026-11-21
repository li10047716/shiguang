/// 通用界面容器。
///
/// - [AppBackground]：全屏不透明底色（跟随主题 surfaceContainerLow）。
/// - [FlatCard]：平面卡片容器，无毛玻璃、无描边、无投影。
/// - [FlatRoundButton]：平面圆形图标按钮，无描边、无投影。
/// - [FlatDialog]：居中弹窗约束容器。
/// - [NavGlassBar]：仅用于底部三项导航的毛玻璃胶囊。
library;

import 'dart:ui';

import 'package:flutter/material.dart';

/// 全屏不透明底色。
class AppBackground extends StatelessWidget {
  final Widget? child;
  const AppBackground({super.key, this.child});

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
class FlatDialog extends StatelessWidget {
  final Widget child;
  final double minWidth;
  final double maxWidth;

  const FlatDialog({
    super.key,
    required this.child,
    this.minWidth = 340,
    this.maxWidth = 420,
  });

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    final mw = maxWidth.clamp(0.0, sw - 32);
    final mn = minWidth > mw ? mw : minWidth;
    // 提供 Material 祖先：ChoiceChip/TextButton 等组件依赖它
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: mn, maxWidth: mw),
        child: Material(
          type: MaterialType.transparency,
          child: child,
        ),
      ),
    );
  }
}

/// 平面圆形图标按钮。
class FlatRoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final double iconSize;

  /// 保留旧参数签名，调用点无需修改；不再产生投影。
  final bool shadow;

  const FlatRoundButton({
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
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: iconSize, color: color ?? cs.onSurface),
        ),
      ),
    );
  }
}

/// 平面卡片容器。
///
/// [blur] / [tintOpacity] / [border] / [shadow] 仅为兼容旧调用点保留，
/// 不再产生毛玻璃、半透明、描边或投影效果。
class FlatCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final double tintOpacity;
  final Border? border;
  final bool shadow;

  const FlatCard({
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
      ),
      child: child,
    );
  }
}

/// 底部三项导航专用的毛玻璃胶囊。
///
/// 这是全应用唯一保留玻璃效果的位置。
class NavGlassBar extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;

  const NavGlassBar({
    super.key,
    required this.child,
    this.radius = 28,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
