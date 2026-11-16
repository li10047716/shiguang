import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

/// 临时验证页：确认 liquid_glass_easy 在 Windows 桌面能编译并渲染。
/// 用法：临时把 home 指向 GlassProbePage 跑一次，验证后删除本文件。
class GlassProbePage extends StatelessWidget {
  const GlassProbePage({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: LiquidGlassView(
          backgroundWidget: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFD9E8FF), Color(0xFFE9E3FF), Color(0xFFD8F2E6)],
              ),
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Align(
                alignment: const Alignment(0, -0.3),
                child: SizedBox(
                  width: 260,
                  height: 120,
                  child: LiquidGlassLens(
                    style: const LiquidGlassStyle(
                      shape: LiquidGlassShape.roundedRectangle(cornerRadius: 36),
                      color: Color(0x40FFFFFF),
                    ),
                    child: const Center(
                      child: Text('glass lens', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: const Alignment(0, 0.3),
                child: LiquidGlassButton(
                  icon: Icons.favorite_rounded,
                  width: 88,
                  height: 88,
                  iconSize: 34,
                  padding: EdgeInsets.zero,
                  style: const LiquidGlassStyle(
                    shape: LiquidGlassShape.roundedRectangle(cornerRadius: 44),
                    color: Color(0x40FFFFFF),
                  ),
                  touch: LiquidGlassTouch.flexing(LiquidGlassFlex()),
                  onPressed: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
