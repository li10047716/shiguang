# ios1114.ipa 书架页逆向重建（从 App.framework AOT 二进制提取）

> 来源：`D:\QQNT\Downloads\ios1114.ipa` → `Payload/Runner.app/Frameworks/App.framework/App`（33MB Dart AOT 机器码）
> 提取方法：UTF-16LE 字符串扫描（Dart AOT 字符串以 UTF-16 存储）+ AOT 保留符号。**这不是源码，是逆向出的字符串/符号结构，可用于复刻 UI。**
>
> 关键：包名实际是 `newread`（`package:newread/...`），源码路径完整保留，书架页 = `pages/bookshelf_page.dart`。

## 〇、App 包结构（源码路径逆向，书架相关加粗）
```
package:newread/
  main.dart                 # 入口
  pages/
    bookshelf_page.dart     # ★ 书架页
    main_page.dart          # 底部导航壳
    home/                   # 首页
      home_page.dart
      components/library_components.dart  # ★ 书架组件
      widgets/home_card.dart
    discovery_page.dart / discovery_page_new.dart
    me_page.dart
    read/read_page.dart     # 阅读器
    history/history_page.dart
  data/
    bookself.dart           # ★ 书架数据模型
    bookdata.dart
    groupdata.dart          # ★ 书架分组
    home_data_service.dart / home_snapshot.dart
  models/
    book.dart               # ★ 书籍模型
    source.dart / bookchapter.dart
  storage/
    storage.dart / setting.dart   # ★ 书架设置（宫格列数/缩放/排序）
  util/
    bookList.dart           # ★ 书架列表工具
    cahce/imagecache.dart
  liquid_glass_easy         # 液态玻璃库（shader + Flutter API）
```


## 一、App 身份
- 包名 `com.q9uo11.nread`，应用名 **read**，版本 6.0（build 1114），MinimumOS 15.0，Xcode 27.1
- 支持文档类型：JSON / TXT / EPUB / MOBI / AZW3；权限：相机（扫码）、相册；后台模式 fetch/audio；URL scheme `qread`

## 二、书架页核心类（AOT 保留符号）
| 符号 | 含义 |
|---|---|
| `BookshelfPage` / `_BookshelfPageState` | 书架页主体 |
| `getBookshelfPage` | 取书架分页（本地/云） |
| `getBookshelfNewr` | 取「最近更新」排序数据 |
| `addBookShelf` / `delBookShelf` / `addToBookshelf` | 加入/移除书架、加入确认 |
| `_showBookshelfColumnsDialog` / `_showBookshelfColumnsDialog2` | 宫格列数设置弹窗 |
| `_showBookshelfScaleDialog` / `_showBookshelfScaleDialog2` | 宫格缩放（50–200%）设置弹窗 |
| `showAddToBookshelfReminder` | 退出阅读页未加入书架的提醒 |

## 三、书架页 UI 结构（逆向推断）

### 顶部操作区（右上）
搜索 / 排序 / 分组 / 添加 / 多选（全选→批量删除）——对应文案：
- 「书架搜索」「选择排序方式」「书架排序」「分组管理」「编辑分组」「全部分组」「批量删除」「取消全选」「文件导入」

### 视图模式（两种，可切换）
1. **宫格模式**：`宫格列数`、`宫格缩放`（50–200%）、`宫格模式下使用卡片样式显示书本`、`调整书架宫格时书本的显示大小`
2. **列表模式**：`书架为列表显示时每行个数，0为自适应`、`书架缩放比例`、`调整书架为列表时书本的显示大小`

### 排序方式
`手动排序` / `最近添加` / `最近更新`（`getBookshelfNewr`）/ 按阅读状态。`书架书籍按阅读状态统计`（`书架里还没开始读的书`/`书架里的书都开始读了`）

### 书架卡片字段
- 封面（`是否在封面显示书本类型` → 封面角标）
- 书名、作者
- `最新章节` / `最近更新` / `阅读进度`（`上次阅读进度：`、`没有进度`）
- `未读章节` 红点（`书架页是否显示未读章节红点`）
- 操作：`换源` / `缓存` / `更新` / `移除`（`清除缓存`、`确认移除`、`更新进度`）

### 书架分组（云端/本地）
- `全部分组`、`分组管理`、`编辑分组`、`选择要加入的书架分组`
- 云端：`启用云端书架`、`云端书架`、`云端书架同步失败`、`开启书架同步成功`、`书架备份无法和云端书架同时打开`、`恢复云端书架`、`管理书架备份`

### 空态
- `书架还是空的`、`书架还没有书，先去添加书籍吧`、`还没有阅读记录，去书架挑一本吧`

## 四、书架数据层（逆向推断）
- 本地存储：书架书籍列表（含分组、排序、阅读状态统计）
- 云端同步：WebDAV / 云端书架备份（自动同步开关、备份设备管理）
- 缓存：`只清理不在书架的书本缓存`、`个不存在于书架的文件`、`个不在书架的缓存文件夹`、`检测到旧版本的书本缓存文件夹，是否清理？`
- 换源去重：`当前已有同源书本在书架…`、`换源失败，书架已存在当前书本`、`加入书架失败，已有相同书本在书架了！`

## 五、书架用到的资源（flutter_assets）
- 封面占位：`lib/assets/images/no_cover.jpeg`
- 背景图：`lib/assets/bg/1..14.jpg`（14 张，书架页/阅读器背景壁纸）
- 图标：`lib/assets/images/icons/1..20`（书架/发现/我的等 tab 与操作图标）
- 字体：`lib/fonts/circle/AlimamaFangYuanTiVF-Thin.ttf`、`lib/fonts/boldface/AlimamaShuHeiTi-Bold.ttf`

## 六、书架所在的技术栈
- **Flutter AOT**（`App.framework/App` 机器码 + `flutter_assets` 标准布局）
- 液态玻璃效果来自 `liquid_glass_easy` 包的 **Metal fragment shader**（`packages/liquid_glass_easy/lib/assets/shaders/*.frag`）
- 含 WebF（`webf`/`webf_bridge`/`quickjs`/`objective_c`/`domino.bundle.js`），但那是 JS 页面模块，书架本体是 Dart

## 七、液态玻璃 API（`liquid_glass_easy`，从 AOT 符号确认）
书架卡片/导航栏/按钮用的玻璃组件与参数（Flutter 侧，Dart AOT 保留符号）：

| API | 说明 |
|---|---|
| `LiquidGlass` / `LiquidGlassView` | 玻璃容器 / 玻璃页面视图 |
| `LiquidGlassAppearance` | 外观：`blurMethod`、`saturation`、`saturationForHSL` |
| `LiquidGlassStyle` | 样式：颜色、描边、厚度（`LiquidGlassLight(thickness:…)`） |
| `LiquidGlassRefraction` | 折射（`refractionIndex` 等） |
| `LiquidGlassCornerStyle` | 圆角样式（超椭圆 squircle） |
| `LiquidGlassLens` / `RenderLiquidGlassLens` | 触控透镜（折射跟随手指） |
| `LiquidGlassShaderClip` | shader 裁剪 |
| `LiquidGlassBatchMode` / `LiquidGlassBatchScope` | 批量渲染优化 |
| `LiquidGlassBlurMethod` | 模糊方法（`fegaussianblur` 等） |
| `LiquidGlassFlexOutline` / `LiquidGlassFlexDeform` | 柔性轮廓/变形 |
| `LiquidGlassAdaptivityDriver` / `LiquidGlassAdaptiveClient` | 自适应驱动 |
| `LiquidGlassStyler` / `LiquidGlassShaders` | 样式器 / shader 集 |

### 金属 shader（`shaders/*.frag`，从 ipa 解出）
- **几何核心**（`liquid_glass_geometry.frag`，4KB）：超椭圆圆角，`powr(x, 0.6)` 圆角指数、0.2893 圆角半径系数、0.7198 内缩——书架卡片圆角就是这套
- **主渲染**：`liquid_glass.frag`（45KB）uniforms：`u_resolution`/`u_touch`（触控折射）/`u_lensGeom`（透镜）/`u_warp`/`u_borderWidth`/`u_borderAlpha`/`u_specularColor`/`u_glowColor`/`u_lensColor`/`u_packA/B/C`/`u_specular2`/`u_lightOpposite`/`u_imageOffset`/`u_honorBackdropAlpha`/`u_shapeAaPx`/`u_shapeScale`/`u_geom`
- **桌面版**：`liquid_glass_desktop.frag`；**Skia 版**：`liquid_glass_skia.frag`/`liquid_glass_border_skia.frag`
- **液体金属球**：`metaball_glass.frag`/`metaball_glass_desktop.frag`/`metaball_glass_skia.frag`/`metaball_geometry.frag`（164KB，液态金属球/粘连动画）

> 这些是 **Metal 编译中间码**（`#include <metal_stdlib>` + `fragment` 函数），不是原始 GLSL；参数已硬编码。真正的可调参数在 Dart 侧 `LiquidGlassAppearance/Style/Refraction`，但 AOT 内联了构造实参，无法直接读数值——需通过 `liquid_glass_easy` 的 pub 包源码或实测确定。
