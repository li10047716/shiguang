# ReadingApp（悦读）

一款 Flutter 小说阅读 App。通过「规则书源 + 原生适配器」聚合多站小说，支持在线搜索、目录阅读与本地 TXT/文字版 EPUB 导入。当前版本仅保留小说阅读功能，不提供漫画或视频。

## 快速开始（Windows）

双击项目根目录的 **`启动应用.bat`**，按菜单选择：

```
[1] 直接启动          → 用已编译的 exe，最快
[2] 重新编译后启动    → 改了 Dart 代码后用
[3] 修复依赖并编译启动 → 项目换过位置 / 首次运行 / 依赖报错
[4] 仅修复依赖        → flutter pub get
[5] 热重载开发模式    → 改代码后按 r 即时生效，R 重启，q 退出
[0] 退出
```

脚本会自动检测 Flutter 路径（环境变量 `FLUTTER_HOME` → PATH → 常见安装位置）。也可手动命令启动：

```bash
flutter pub get
flutter run -d windows
```

常见问题：

- 报「找不到 dio / riverpod」等依赖错误 → 执行菜单 `[4]`（项目移动过位置会导致依赖路径失效）
- 编译报缺少 `build/native_assets/windows` → 手动建该目录后重新编译

## 主要功能

- **书架**：网格/列表、分组筛选、更新检查、批量管理、本地小说导入（TXT/文字版 EPUB）、秒开直读
- **搜索**：多书源并发聚合，按「书名+作者」去重，一条结果可展开切换来源
- **发现**：榜单/分类标签，书源下拉切换、无限滚动、双层缓存
- **阅读器**：自研 `TextPainter` 精确分页、4 种翻页（含 3D）、字号行距背景设置、亮度与自动阅读、白噪音、夜间切换、书签与划线笔记、章节预载与离线缓存
- **我的**：阅读统计（7 天柱状图）、书签/笔记管理、书源导入导出与启停、主题/缓存/备份恢复设置

## 书源

- **内置规则书源（4 个）**：速读谷、速读谷(备用)、全本小说网、八一中文网
- **原生适配器（7 个）**：七猫、书旗、得奇、八叉、爱丽丝、本地小说、爱看吧(ik8.net，默认关闭，需自行开启)
- 支持在「我的 → 书源」导入/导出自定义 JSON 规则书源，可单独启停

规则格式为类 Legado 风格 JSON，支持 CSS 选择器、`||` 回退链、`##正则##替换`、`:contains()` 等语法，详见 [ARCHITECTURE.md](ARCHITECTURE.md)。

> 注：速读谷主站正文存在服务端混淆乱码，客户端只能部分修复；备用站 `sudugu520.com` 速度更快，主站慢时建议切换。

## 目录结构

```
lib/         应用源码（models / services / sources / ui / utils）
android/     Android 工程
ios/         iOS 工程（Info.plist 允许 HTTP 书源）
windows/     Windows 桌面工程
assets/      白噪音音频
.github/     iOS 自动构建 CI
archive/     探索性产物归档（详见 archive/README.md）
启动应用.bat  Windows 启动与验证脚本
ARCHITECTURE.md  架构设计与技术细节
```

## 构建

```bash
flutter build windows --debug   # Windows
flutter build apk               # Android
flutter build ios               # iOS（需 macOS + Xcode）
```

iOS CI 见 `.github/workflows/ios.yml`，自动打包 IPA 并上传到 release。

## 更多

架构设计、规则语法、缓存策略、已知问题与历史排查记录见 [ARCHITECTURE.md](ARCHITECTURE.md)。
