/// 玻璃下拉菜单：锚点按钮 + 点击展开 Overlay 玻璃面板。
///
/// 样式与发现页「书源选择」下拉一致：白色玻璃圆角面板、每项统一高 40、
/// 选中项浅蓝底 + 蓝字 + radio 图标；动作项可传 [GlassMenuItem.leadingIcon]。
library;

import 'package:flutter/material.dart';

import '../glass.dart';

void _noop() {}

/// 菜单项
class GlassMenuItem {
  final String label;

  /// 单选态：显示 radio 图标（选中蓝 / 未选灰），选中项浅蓝底
  final bool selected;

  /// 动作项图标（不显示 radio，改用该图标）
  final IconData? leadingIcon;

  /// 分隔线项（不渲染行，仅一条分隔线；onTap 忽略）
  final bool divider;

  final VoidCallback onTap;

  const GlassMenuItem({
    required this.label,
    this.selected = false,
    this.leadingIcon,
    this.divider = false,
    this.onTap = _noop,
  });
}

class GlassMenu extends StatefulWidget {
  /// 锚点按钮内容（点击展开菜单）
  final Widget child;

  final List<GlassMenuItem> items;

  /// 菜单面板宽度
  final double width;

  const GlassMenu({
    super.key,
    required this.items,
    this.width = 180,
    required this.child,
  });

  @override
  State<GlassMenu> createState() => _GlassMenuState();
}

class _GlassMenuState extends State<GlassMenu> {
  static const Color _blue = Color(0xFF3E8EF7);

  final GlobalKey _key = GlobalKey();
  OverlayEntry? _overlay;

  void _toggle() {
    if (_overlay != null) {
      _close();
      return;
    }
    final ctx = _key.currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final size = box.size;
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (_) => _layer(topLeft, size.width, size.height),
    );
    _overlay = entry;
    overlay.insert(entry);
  }

  void _close() {
    _overlay?.remove();
    _overlay = null;
  }

  Widget _layer(Offset topLeft, double buttonWidth, double buttonHeight) {
    final menuW = widget.width;
    final screen = MediaQuery.of(context).size;
    var menuH = 12.0;
    for (final it in widget.items) {
      menuH += it.divider ? 9.0 : 40.0;
    }
    // 菜单水平中心对齐按钮中心（clamp 仅防出屏）
    final left = (topLeft.dx + buttonWidth / 2 - menuW / 2)
        .clamp(8.0, screen.width - menuW - 8);
    final top = topLeft.dy + buttonHeight + 4;
    return Stack(
      children: [
        // 点击空白处关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
          ),
        ),
        Positioned(
          left: left,
          top: top.clamp(0.0, screen.height - menuH - 8),
          width: menuW,
          child: Glass(
            radius: 14,
            blur: 18,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final it in widget.items) _item(it),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _item(GlassMenuItem it) {
    if (it.divider) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Divider(height: 1, indent: 14, endIndent: 14),
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () {
          _close();
          it.onTap();
        },
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          color:
              it.selected ? _blue.withValues(alpha: 0.14) : Colors.transparent,
          child: Row(
            children: [
              if (it.leadingIcon != null)
                Icon(
                  it.leadingIcon,
                  size: 16,
                  color: it.selected ? _blue : Colors.grey.shade500,
                )
              else
                Icon(
                  it.selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 15,
                  color: it.selected ? _blue : Colors.grey.shade500,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  it.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: it.selected ? _blue : const Color(0xFF222222),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _key,
      onTap: _toggle,
      behavior: HitTestBehavior.opaque,
      child: widget.child,
    );
  }
}
