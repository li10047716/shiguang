import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 书架 3D 空间样例页：三种方案一键切换，占位封面，跑起来选方向。
/// 用法：临时把入口 home 指向本页，看完删除。
class Shelf3DProbePage extends StatefulWidget {
  const Shelf3DProbePage({super.key});

  @override
  State<Shelf3DProbePage> createState() => _Shelf3DProbePageState();
}

class _Shelf3DProbePageState extends State<Shelf3DProbePage> {
  int _mode = 0; // 0=透视宫格 1=封面流 2=旋转书架

  // 占位封面：12 本书，多彩渐变模拟封面
  static const _titles = [
    '凡人修仙传', '斗破苍穹', '诡秘之主', '大奉打更人', '夜的命名术', '道诡异仙',
    '深空彼岸', '夜无疆', '宿命之环', '玄鉴仙族', '赤心巡天', '光阴之外',
  ];
  static const _palette = [
    [Color(0xFF3E8EF7), Color(0xFF6A5CFF)],
    [Color(0xFFF76707), Color(0xFFFFC078)],
    [Color(0xFF12B886), Color(0xFF63E6BE)],
    [Color(0xFFE64980), Color(0xFFFFA8C5)],
    [Color(0xFF7048E8), Color(0xFFB197FC)],
    [Color(0xFF1098AD), Color(0xFF66D9E8)],
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF10131A),
      body: Column(
        children: [
          // 顶部切换（横向滚动，7 种）
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 44, 12, 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _chip(0, '透视宫格'),
                  const SizedBox(width: 8),
                  _chip(1, '封面流'),
                  const SizedBox(width: 8),
                  _chip(2, '旋转书架'),
                  const SizedBox(width: 8),
                  _chip(3, '层叠卡片'),
                  const SizedBox(width: 8),
                  _chip(4, '3D走廊'),
                  const SizedBox(width: 8),
                  _chip(5, '3D圆柱'),
                  const SizedBox(width: 8),
                  _chip(6, '3D立方体'),
                ],
              ),
            ),
          ),
          Expanded(
            child: switch (_mode) {
              0 => _PerspectiveGrid(titles: _titles, palette: _palette),
              1 => _CoverFlow(titles: _titles, palette: _palette),
              2 => _SpinShelf(titles: _titles, palette: _palette),
              3 => _CardStack(titles: _titles, palette: _palette),
              4 => _Corridor(titles: _titles, palette: _palette),
              5 => _Cylinder(titles: _titles, palette: _palette),
              _ => _Cube(titles: _titles, palette: _palette),
            },
          ),
        ],
      ),
    );
  }

  Widget _chip(int mode, String label) {
    final active = _mode == mode;
    return GestureDetector(
      onTap: () => setState(() => _mode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF3E8EF7) : const Color(0xFF232A36),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : const Color(0xFF8A94A6),
            fontSize: 13,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// 占位封面卡片（多彩渐变 + 书名）
class _Cover extends StatelessWidget {
  final String title;
  final List<Color> colors;
  const _Cover(this.title, this.colors);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: colors.first.withValues(alpha: 0.4),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 3,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================
// 方案 1：3D 透视宫格（整体透视 + 拖拽绕 Y 轴 / 俯仰）
// =============================================================
class _PerspectiveGrid extends StatefulWidget {
  final List<String> titles;
  final List<List<Color>> palette;
  const _PerspectiveGrid({required this.titles, required this.palette});

  @override
  State<_PerspectiveGrid> createState() => _PerspectiveGridState();
}

class _PerspectiveGridState extends State<_PerspectiveGrid> {
  double _rotY = 0;
  double _rotX = 0.25; // 默认轻微俯视

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (d) => setState(() => _rotY += d.delta.dx * 0.006),
      onVerticalDragUpdate: (d) => setState(() {
        _rotX = (_rotX + d.delta.dy * 0.005).clamp(-0.8, 1.2);
      }),
      child: Center(
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0012) // 透视
            ..rotateX(_rotX)
            ..rotateY(_rotY),
          child: SizedBox(
            width: 620,
            height: 480,
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 0.62,
                crossAxisSpacing: 14,
                mainAxisSpacing: 18,
              ),
              itemCount: widget.titles.length,
              itemBuilder: (context, i) => _Cover(
                widget.titles[i],
                widget.palette[i % widget.palette.length],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================
// 方案 2：3D 封面流（Cover Flow，PageView + 旋转/缩放/位移）
// =============================================================
class _CoverFlow extends StatefulWidget {
  final List<String> titles;
  final List<List<Color>> palette;
  const _CoverFlow({required this.titles, required this.palette});

  @override
  State<_CoverFlow> createState() => _CoverFlowState();
}

class _CoverFlowState extends State<_CoverFlow> {
  late final PageController _ctrl =
      PageController(viewportFraction: 0.42);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _ctrl,
      itemCount: widget.titles.length,
      itemBuilder: (context, i) {
        return AnimatedBuilder(
          animation: _ctrl,
          builder: (context, child) {
            double page = _ctrl.hasClients ? _ctrl.page ?? 0 : 0;
            final offset = (page - i).clamp(-1.0, 1.0);
            final angle = offset * 0.55; // 两侧旋转角
            final scale = 1 - (offset.abs() * 0.12);
            final transX = offset.abs() * 30;
            final opacity = 1 - (offset.abs() * 0.35);
            return Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateY(angle)
                  ..scaleByDouble(scale, scale, scale, 1)
                  ..translateByDouble(transX * offset.sign, 0, 0, 1),
                child: child,
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 40),
            child: _Cover(
              widget.titles[i],
              widget.palette[i % widget.palette.length],
            ),
          ),
        );
      },
    );
  }
}

// =============================================================
// 方案 3：3D 旋转书架（环形排布 + 拖拽绕中心轴旋转）
// =============================================================
class _SpinShelf extends StatefulWidget {
  final List<String> titles;
  final List<List<Color>> palette;
  const _SpinShelf({required this.titles, required this.palette});

  @override
  State<_SpinShelf> createState() => _SpinShelfState();
}

class _SpinShelfState extends State<_SpinShelf> {
  double _angle = 0;

  @override
  Widget build(BuildContext context) {
    final n = widget.titles.length;
    return GestureDetector(
      onHorizontalDragUpdate: (d) => setState(() => _angle += d.delta.dx * 0.01),
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth, h = c.maxHeight;
          final cx = w / 2, cy = h / 2;
          final radius = math.min(w, h) * 0.42;
          final items = <Widget>[];
          for (int i = 0; i < n; i++) {
            final a = _angle + (i / n) * 2 * math.pi;
            final x = math.cos(a) * radius;
            final z = math.sin(a); // -1(后) ~ 1(前)
            final scale = 0.55 + (z + 1) * 0.22; // 前大后小
            final opacity = 0.35 + (z + 1) * 0.32;
            items.add(
              Positioned(
                left: cx + x - 55,
                top: cy - 85,
                child: Opacity(
                  opacity: opacity.clamp(0.0, 1.0),
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.002)
                      ..scaleByDouble(scale, scale, scale, 1)
                      ..rotateY((math.cos(a) * 0.5).toDouble()),
                    child: SizedBox(
                      width: 110,
                      height: 170,
                      child: _Cover(
                        widget.titles[i],
                        widget.palette[i % widget.palette.length],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          // 后画前面的（z 大者靠前）
          return Stack(children: items);
        },
      ),
    );
  }
}

// =============================================================
// 方案 4：层叠卡片堆（封面堆叠，滑动露出下一张，3D 倾斜）
// =============================================================
class _CardStack extends StatefulWidget {
  final List<String> titles;
  final List<List<Color>> palette;
  const _CardStack({required this.titles, required this.palette});

  @override
  State<_CardStack> createState() => _CardStackState();
}

class _CardStackState extends State<_CardStack> {
  int _top = 0;

  @override
  Widget build(BuildContext context) {
    final n = widget.titles.length;
    final visible = <Widget>[];
    // 从最底下一张往上叠（后画的在上）
    final count = n > 4 ? 4 : n;
    for (int k = count - 1; k >= 0; k--) {
      final idx = (_top + k) % n;
      final depth = k; // 0=最上
      final offset = depth * 16.0;
      final angle = -depth * 0.06;
      final scale = 1 - depth * 0.05;
      visible.add(
        Positioned.fill(
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.001)
              ..rotateY(angle)
              ..scaleByDouble(scale, scale, scale, 1)
              ..translateByDouble(offset, offset * 0.5, 0, 1),
            child: GestureDetector(
              onTap: () => setState(() => _top = (_top + 1) % n),
              onHorizontalDragEnd: (d) =>
                  setState(() => _top = (_top + 1) % n),
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: _Cover(widget.titles[idx],
                    widget.palette[idx % widget.palette.length]),
              ),
            ),
          ),
        ),
      );
    }
    return Stack(children: visible);
  }
}

// =============================================================
// 方案 5：3D 走廊（书本沿两侧纵深排，中间封面，透视强烈）
// =============================================================
class _Corridor extends StatefulWidget {
  final List<String> titles;
  final List<List<Color>> palette;
  const _Corridor({required this.titles, required this.palette});

  @override
  State<_Corridor> createState() => _CorridorState();
}

class _CorridorState extends State<_Corridor> {
  @override
  Widget build(BuildContext context) {
    final n = widget.titles.length;
    return PageView.builder(
      itemCount: n,
      itemBuilder: (context, i) {
        // 两侧纵深书排：左右各 4 本，往后缩小+透明，形成走廊
        final side = <Widget>[];
        for (int k = 0; k < 4; k++) {
          final depth = k + 1;
          final s = 1 - depth * 0.16;
          final op = (1 - depth * 0.22).clamp(0.0, 1.0);
          side.add(Positioned(
            left: 24 - depth * 14,
            top: 90 + depth * 36,
            child: Opacity(
              opacity: op,
              child: Transform.scale(
                scale: s,
                child: SizedBox(
                  width: 110,
                  height: 160,
                  child: _Cover(
                    widget.titles[(i + depth) % n],
                    widget.palette[(i + depth) % widget.palette.length],
                  ),
                ),
              ),
            ),
          ));
          side.add(Positioned(
            right: 24 - depth * 14,
            top: 90 + depth * 36,
            child: Opacity(
              opacity: op,
              child: Transform.scale(
                scale: s,
                child: SizedBox(
                  width: 110,
                  height: 160,
                  child: _Cover(
                    widget.titles[(i - depth + n) % n],
                    widget.palette[(i - depth + n) % widget.palette.length],
                  ),
                ),
              ),
            ),
          ));
        }
        // 中间当前书
        side.add(
          Center(
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.001)
                ..rotateY(0),
              child: SizedBox(
                width: 180,
                height: 260,
                child: _Cover(widget.titles[i],
                    widget.palette[i % widget.palette.length]),
              ),
            ),
          ),
        );
        return Stack(children: side);
      },
    );
  }
}

// =============================================================
// 方案 6：3D 圆柱书架（书本贴圆柱面朝外，拖拽旋转，见书脊）
// =============================================================
class _Cylinder extends StatefulWidget {
  final List<String> titles;
  final List<List<Color>> palette;
  const _Cylinder({required this.titles, required this.palette});

  @override
  State<_Cylinder> createState() => _CylinderState();
}

class _CylinderState extends State<_Cylinder> {
  double _angle = 0;

  @override
  Widget build(BuildContext context) {
    final n = widget.titles.length;
    return GestureDetector(
      onHorizontalDragUpdate: (d) => setState(() => _angle += d.delta.dx * 0.01),
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth, h = c.maxHeight;
          final cx = w / 2, cy = h / 2;
          final radius = math.min(w, h) * 0.34;
          final items = <Widget>[];
          for (int i = 0; i < n; i++) {
            final a = _angle + (i / n) * 2 * math.pi;
            final x = math.cos(a) * radius;
            final z = math.sin(a);
            final s = 0.5 + (z + 1) * 0.2;
            final op = (0.3 + (z + 1) * 0.35).clamp(0.0, 1.0);
            // 书脊朝向观察者的窄条（侧转），正对时全封面
            items.add(
              Positioned(
                left: cx + x - 60,
                top: cy - 90,
                child: Opacity(
                  opacity: op,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.002)
                      ..rotateY(-a + math.pi / 2)
                      ..scaleByDouble(s, s, s, 1),
                    child: SizedBox(
                      width: 120,
                      height: 180,
                      child: _Cover(widget.titles[i],
                          widget.palette[i % widget.palette.length]),
                    ),
                  ),
                ),
              ),
            );
          }
          return Stack(children: items);
        },
      ),
    );
  }
}

// =============================================================
// 方案 7：3D 立方体（封面贴立方体面，拖拽绕轴旋转）
// =============================================================
class _Cube extends StatefulWidget {
  final List<String> titles;
  final List<List<Color>> palette;
  const _Cube({required this.titles, required this.palette});

  @override
  State<_Cube> createState() => _CubeState();
}

class _CubeState extends State<_Cube> {
  double _rx = 0;
  double _ry = 0;

  @override
  Widget build(BuildContext context) {
    final n = widget.titles.length;
    final half = 90.0;
    Widget face(int idx) => Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.palette[idx % widget.palette.length],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: Text(
              widget.titles[idx],
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ),
        );
    return GestureDetector(
      onHorizontalDragUpdate: (d) => setState(() => _ry += d.delta.dx * 0.01),
      onVerticalDragUpdate: (d) => setState(() => _rx += d.delta.dy * 0.01),
      child: Center(
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.002)
            ..rotateX(_rx)
            ..rotateY(_ry),
          child: SizedBox(
            width: half * 2,
            height: half * 2,
            child: Stack(
              children: [
                // 前面
                Positioned.fill(child: face(0 % n)),
                // 后面（绕 Y 转 180）
                Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()..rotateY(3.14159),
                  child: Positioned.fill(child: face(1 % n)),
                ),
                // 右面（绕 Y +90）
                Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0)
                    ..rotateY(1.5708)
                    ..translateByDouble(half, 0, 0, 1),
                  child: Positioned.fill(child: face(2 % n)),
                ),
                // 左面（绕 Y -90）
                Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..rotateY(-1.5708)
                    ..translateByDouble(-half, 0, 0, 1),
                  child: Positioned.fill(child: face(3 % n)),
                ),
                // 顶面（绕 X -90）
                Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..rotateX(-1.5708)
                    ..translateByDouble(0, -half, 0, 1),
                  child: Positioned.fill(child: face(4 % n)),
                ),
                // 底面（绕 X +90）
                Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..rotateX(1.5708)
                    ..translateByDouble(0, half, 0, 1),
                  child: Positioned.fill(child: face(5 % n)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
