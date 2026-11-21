# liquid_glass_easy 5.2.0 玻璃参数参考（目标 app ios1114 用的同款）

> 来源：pub.dev `liquid_glass_easy` **5.2.0**（作者 AhmeedGamil，github.com/AhmeedGamil/liquid_glass_easy）源码，
> 与 ipa 里 `packages/liquid_glass_easy/` 一致。以下为**库默认值**（目标 app 若未显式覆盖即生效）。

## 1. LiquidGlassStyle —— 玻璃整体样式（书架卡片/胶囊首选）
```dart
const LiquidGlassStyle(
  shape: null,                    // null = 消费方默认（导航胶囊=高度追踪capsule）
  specular: null,                 // null = LiquidGlassLight.specular()
  glow: null,                     // null = 无侧光（shader跳过）
  refractionIndex: 1.1,           // 1.0=不弯，1.02=清晰边缘，1.5=很强
  refractionWidth: 12.0,          // 弯曲带宽度(逻辑px)
  magnification: 1.0,             // 放大（1.0=无）
  dispersion: 0,                  // 色散/色边（0=无，1.3=细边，6.6=强；推荐0~13）
  saturation: 1.0,                // 饱和度（1.0=不变，0=灰）
  blur: 0.0,                      // 高斯模糊sigma（0=不模糊）
  color: Color(0x00000000),       // 玻璃底色tint（默认透明！）
  shadow: null,                   // 接触阴影（null=无）
  adaptivity: null,               // iOS自适应明暗（null=关）
  liteGlass: false,               // 无shader的"lite玻璃"（磨砂+漆边）
)
```

## 2. LiquidGlassRefraction —— 折射组
```dart
const LiquidGlassRefraction(
  refractionIndex: 1.1,   // 弯曲强度
  refractionWidth: 12,    // 弯曲带宽
  magnification: 1,       // 放大
  dispersion: 0,          // 色散
)
```

## 3. LiquidGlassAppearance —— 材质组
```dart
const LiquidGlassAppearance(
  saturation: 1.0,          // 饱和度
  blur: 0.0,                // 模糊sigma
  color: Colors.transparent, // 底色（默认全透明）
  shadow: null,             // 接触阴影
)
```

## 4. LiquidGlassLight —— 高光/侧光
```dart
const LiquidGlassLight.specular({  // 高光：细窄亮带
  thickness: 5.0,     // 深入深度(px)，5=specular
  sharpness: 0.5,     // 锐度（0.5=默认细带，1.0=前40%实心）
  angle: 39.0,        // 光轴角度（39°=对角）
  spread: 0.9,        // 环绕范围（0.9=宽弧）
  intensity: 1.0,     // 强度（0=关，推荐0~3）
  oppositeIntensity: 1.0, // 远端弧强度倍数
  color: null,        // null=取背景色提亮；可给白色
})
const LiquidGlassLight.glow({     // 侧光：宽柔带
  thickness: 10.0,    // 10=glow
  angle: 90.0,        // 90°=上下
  spread: 0.5,
  intensity: 1.0,
  oppositeIntensity: 1.0,
  color: null,
}) : sharpness = 0.5;
```

## 5. 底部导航栏（LiquidGlassTabBar / 胶囊）—— 书架所在页面
```dart
// 玻璃胶囊（moving pill）
const LiquidGlassNavBarStyle(
  blur: 0,
  refractionIndex: 1.015,   // 导航胶囊弯曲很轻
  refractionWidth: 24,      // 带宽较宽
  // effectiveGlass = LiquidGlassStyle.groups(
  //   specular: LiquidGlassLight.specular(), ...)
)
// 选中胶囊色 / 静态胶囊 / 容器
pillColor: Color(0x1CFFFFFF),           // 胶囊：白11%透明
selectedColor: Color(0xFF0088FF),        // 选中tab图标/文字：蓝
// tab容器底色: Color(0x46AEAEB2)         // 灰（0x46=27%）
// 接触阴影: LiquidGlassShadow(blur:9, opacity:0.3, inset:0)
```

## 6. 形状（圆角）
- `LiquidGlassShape.roundedRectangle(cornerRadius: 36)`（示例）
- 几何核心（shader）：超椭圆 squircle，`powr(x, 0.6)`、半径系数 `0.2893`、内缩 `0.7198`

## 7. 关键对比：咱们当前实现 vs 目标默认
| 项 | 目标（liquid_glass_easy 默认） | 咱们（glass.dart） |
|---|---|---|
| 底色 | **Color(0x00000000) 全透明** | `Colors.white alpha 0.28` |
| 模糊 | `blur 0`（导航胶囊）/ `blur 2`（示例） | `BackdropFilter blur 3` |
| 弯曲 | `refractionIndex 1.1` | 无（无折射） |
| 高光 | `specular thickness 5, 39°, spread 0.9` | 白描边 `alpha 0.35` 全边 |
| 侧光 | `glow thickness 10, 90°` | 无 |
| 阴影 | `shadow blur 9, opacity 0.3` | `black 0.10` |
| 圆角 | squircle 超椭圆 | 普通圆角 `BorderRadius.circular` |

**结论**：目标的玻璃是**无底色、靠折射+高光+侧光**出效果；咱们目前是**白底+模糊+全边描边**。要更像目标，需要把底色往透明走、加折射和双高光——但这是视觉大改，建议逐步来。
