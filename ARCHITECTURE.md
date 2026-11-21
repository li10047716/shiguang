# ReadingApp 架构设计

> 最后更新：2026-11-21。以实际代码为准（早期文档写于 11-08，内容已大幅扩展）。

一款 Flutter 小说阅读软件，采用**规则书源 + 原生适配器**双轨方式聚合小说站点，搜索结果多源展示。当前版本只保留在线与本地小说阅读，不包含漫画或视频功能。包名 `reading_app`，iOS 显示名「悦读」。

## 技术选型

| 项 | 选择 | 说明 |
|---|---|---|
| 框架 | Flutter 3.x | Dart SDK `^3.13.7`；Android / iOS / Windows 三端工程在库 |
| 网络 | `dio` | 响应式缓存、流式接收、失败退避重试、GBK 解码 |
| HTML 解析 | `html` | CSS 选择器规则引擎 |
| 状态管理 | `flutter_riverpod` | 聚合搜索流、主题、书架状态 |
| 本地存储 | `shared_preferences` + JSON 文件 | 书架/进度/设置/缓存，无数据库依赖 |
| 加密签名 | `crypto` | MD5 签名（七猫/书旗等 App 接口） |
| 内容解密 | 纯 Dart AES-128-CBC | `utils/aes.dart`，七猫正文解密 |
| 本地小说 | `archive` + `path_provider` + `file_picker` | TXT/文字版 EPUB 导入与解压 |
| 音频 | `audioplayers` | 阅读页白噪音循环 |
| 编码兼容 | `fast_gbk` | GBK 站点解码与乱码修复 |
| UI | Material 3 + `BackdropFilter` | 界面整体为平面组件；仅底部导航胶囊保留毛玻璃效果 |

## 模块划分（lib/）

```
lib/
├── main.dart                       # 入口：恢复主题、ProviderScope
├── models/
│   ├── book.dart                   # Book / Chapter，normalizeKey 用于聚合去重
│   ├── book_source.dart            # 小说书源规则模型（旧类型值仅用于兼容历史数据）
│   ├── content.dart                # 小说内容载体：章节标题、书名与段落
│   └── discover.dart               # 榜单/分类标签与发现结果
├── services/
│   ├── http_client.dart            # 全站网络核心（UA/安全头/缓存/流式/重试）
│   ├── search_aggregator.dart      # 并发聚合搜索、边到边合并
│   ├── library.dart                # 书架与阅读进度
│   ├── chapter_cache.dart          # 正文磁盘缓存（离线可读）+ 书籍元信息/全局统计/批量清理
│   ├── cache_download.dart         # 统一下载中心：进度上报 + 取消（三处入口共用）
│   ├── toc_cache.dart              # 目录缓存（3 天，支持部分目录）
│   ├── discover_cache.dart         # 发现页缓存（30 分钟）
│   └── marks.dart                  # 书签与划线笔记
├── sources/
│   ├── source.dart                 # NovelSource 统一接口
│   ├── rule_engine.dart            # CSS 规则引擎（选择器/回退/正则后处理）
│   ├── novel_source.dart           # 规则执行器：search/detail/toc/content
│   ├── rule_source.dart            # 把 BookSource 包装成 NovelSource
│   ├── source_registry.dart        # 全局单例：注册/启停/查询，持久化状态
│   ├── builtin/builtin_sources.dart # 4 个内置规则书源 + 自定义书源仓库
│   └── native/                     # 小说原生适配器（见下表）
├── ui/
│   ├── home_shell.dart             # 三 tab 外壳 + 弹性滑动指示器
│   ├── app_theme.dart / glass.dart / widgets/glass_menu.dart
│   ├── search/                     # 搜索页 + 按书名聚合的结果页
│   ├── book/                       # 书籍详情 + 目录页（边抓边显示）
│   ├── reader/                     # 小说阅读器与偏好常量
│   ├── shelf/shelf_page.dart       # 书架：分组/更新检查/本地书/秒开直读
│   ├── discover/discover_page.dart # 榜单/分类发现页，书源切换 + 无限滚动
│   ├── mine/mine_page.dart         # 个人中心：统计/内容/书源/设置四 tab
│   ├── mine/cache_manager_page.dart # 全局缓存管理：列表/占用空间/批量清理
│   └── widgets/                    # 封面缓存组件、类型标签、缓存管理面板
└── utils/
    ├── aes.dart                    # AES-128-CBC 解密（七猫正文）
    └── text_repair.dart            # GBK→UTF-8 逆向乱码修复（仅检测乱码时启用）
```

## 书源体系

### 两类书源

- **规则书源**：JSON 描述抓取规则，由 `rule_engine.dart` + `novel_source.dart` 解释执行，适合结构规整的 CMS 站点，用户可自行导入/导出。
- **原生适配器**：Dart 硬编码类，实现 `NovelSource` 接口，处理签名、AES、代理探测等规则引擎难以表达的站点。

两者对 UI 完全无差别，统一由 `SourceRegistry` 管理。

### 内置规则书源（4 个）

| 书源 | 地址 | 特点 |
|---|---|---|
| 速读谷 | `https://www.sudugu.cc` | 杰奇 CMS；搜索 `/modules/article/search.php?searchkey=`；目录多页翻页合并；正文分 3 页；服务端混淆乱码（见已知问题） |
| 速读谷(备用) | `https://www.sudugu520.com` | 同构站点但路径不同：搜索 `/i/sor.aspx?key=`、榜单 `/paihang/`、分类 `/xuanhuan/` 等拼音路径；详情/目录/正文规则与主站完全兼容；目录单页约 546 章；响应明显快于主站 |
| 全本小说网 | `https://www.qbxs.net` | 常规 HTML 抓取 |
| 八一中文网 | `http://www.81shuku.info` | 常规 HTML 抓取（HTTP 站点） |

两个速读谷源会同时参与聚合搜索，按「书名+作者」自动去重，同一本书显示「2 源」，展开后可手动切换。主站慢时优先选备用源。

### 原生小说适配器（7 个）

| 文件 | 站点/用途 | 关键处理 |
|---|---|---|
| `qm.dart` | 七猫小说 | md5 签名 + AES 正文解密 |
| `shuqi.dart` | 书旗小说 | 设备指纹、XOR 加密、签名、正文多重回退 |
| `dq.dart` | 得奇小说 | 动态 token、Referer 校验 |
| `bc.dart` | 八叉书库 | POST 参数签名、目录并发 |
| `ali.dart` | 爱丽丝书屋 | 自动探测可用代理端口 |
| `localbook.dart` | 本地小说导入 | TXT/文字版 EPUB；书源 ID `loc`，始终强制启用但在书源管理中隐藏 |
| `ik8.dart` | 爱看吧（ik8.net） | 帝国 CMS + `conapi.php` 动态签名 POST 正文；默认关闭 |

书源仓库只加载 `sourceType=novel` 的规则源；漫画/视频来源不再接受或展示。旧的非小说来源配置会保留在本地存储中但不加载。自定义小说书源仍可通过「我的 → 书源」导入/导出。

### 书源规则格式（类 Legado 风格 JSON）

```json
{
  "sourceName": "示例书源",
  "sourceUrl": "https://www.example.com",
  "sourceType": "novel",
  "enabled": true,
  "search": {
    "url": "https://www.example.com/search?q={{key}}&page={{page}}",
    "method": "GET",
    "charset": "utf-8",
    "bookList": ".result-item",
    "name": "h3 a@text",
    "author": ".author@text",
    "cover": "img@src",
    "bookUrl": "h3 a@href",
    "lastChapter": "p:last-child@text"
  },
  "detail": { "name": "h1@text", "intro": ".intro@text", "tocUrl": "" },
  "toc": {
    "chapterList": "#list li",
    "chapterName": "a@text",
    "chapterUrl": "a@href",
    "nextTocUrl": "#pages a.gr@href",
    "pageUrlTemplate": "{{bookUrl}}{{page}}",
    "pageCount": "#pages@text"
  },
  "content": {
    "content": ".con@html",
    "nextContentUrl": ".prenext a:contains(下一页)@href",
    "mergePages": true
  },
  "discover": [
    { "key": "top", "name": "阅读排行", "isRank": true,
      "url": "https://www.example.com/top/{{page}}/",
      "cardList": "div.item", "pageLinks": "a[href*='/top/']" }
  ]
}
```

规则语法（`rule_engine.dart`）：

- `css: <selector>@<text|textNodes|html|href|src|all>` —— CSS 选择器；`css:` 前缀可省略（内置书源均省略）
- `@html` —— 取 innerHTML 并将 `<br>` 转为换行，用于正文分段
- `A || B` —— 回退链，结构不同时兜底
- `##正则##替换` —— 正则后处理；只写 `##正则##` 表示删除匹配部分
- `:contains(文字)` / `:eq(n)` / `:not(...)` —— 伪类筛选
- `{{key}}` / `{{page}}` / `{{bookUrl}}` —— 模板变量
- 相对 URL 由 `absoluteUrl` 自动补全为绝对地址

## 核心机制

### 聚合搜索

1. 输入关键词 → 取所有启用书源
2. 并发请求（并发上限 6，每源超时 12 秒）
3. 每个源返回后立即推入 Stream，先到先展示
4. 按 `normalizeKey`（书名+作者）归一化合并，展示来源数徽标
5. 点击条目展开来源列表，可换源后进入详情

### 网络层（`http_client.dart`）

- 伪装 Chrome UA 与 `Sec-Fetch-*` 等浏览器头，设置 `Referer`
- **60 秒响应缓存**：详情页刚抓过的 URL，点目录时直接命中，绕开站点限流
- **流式接收**：`idleTimeout`（目录 8s / 正文 10s）内无新数据则用已收内容；`maxBytes` 上限（目录/正文 2MB、搜索 3MB）主动断开
- `validateStatus: (_) => true`，404 交由解析层判断，不直接抛异常
- 失败退避重试（默认 2 次，400/800ms），连接超时 20s，接收超时 60s 兜底
- 自动 GBK 解码，支持站点自定义 charset

### 缓存体系

| 缓存 | 位置 | 期限 |
|---|---|---|
| HTTP 响应 | 内存 | 60 秒 |
| 目录 | `toc_cache.dart` | 3 天，支持部分目录（网络失败时先显示旧目录） |
| 正文 | `chapter_cache.dart` | 磁盘，离线可读 |
| 正文下载 | `cache_download.dart` | 统一进度/取消；面板入口在 `widgets/cache_sheet.dart`，全局管理在 `mine/cache_manager_page.dart` |
| 发现页 | `discover_cache.dart` | 30 分钟，双层缓存 |
| 封面 | `cover_image.dart` | 内存 + 磁盘，带 Referer、骨架屏、失败重试 |

### 阅读器

- `reader_page.dart` 用自研 `TextPainter` 精确分页，支持 4 种小说翻页效果（含 3D 仿真）
- 设置项：字号/行距/段距/边距、8 种背景 + 自定义壁纸、亮度、自动阅读、白噪音、夜间自动切换
- 目录/书签/笔记三面板，划线笔记持久化；章节预载 + 磁盘缓存；阅读时长统计（7 天柱状图）
- `open_reader.dart` 统一将书架、目录和详情页的入口交给小说阅读器

## 工程与运行

- **平台工程**：`android/`、`ios/`、`windows/` 各一个目录；iOS `Info.plist` 开启 `NSAllowsArbitraryLoads` 以允许 HTTP 书源
- **CI**：`.github/workflows/ios.yml` 自动构建 IPA 并上传到 release `latest-ipa`
- **本地启动**：双击根目录 `启动应用.bat`（GBK 编码 + `chcp 936`），菜单：
  - `[1]` 直接启动已编译 exe（最快）
  - `[2]` 重新编译后启动
  - `[3]` 修复依赖 + 编译 + 启动
  - `[4]` 仅 `flutter pub get`
  - `[5]` 热重载开发模式（`r` 重载 / `R` 重启 / `q` 退出）
  - `[0]` 退出
  - Flutter 路径自动检测：环境变量 `FLUTTER_HOME` → PATH → 常见安装位置
- **已知构建坑**：项目移动过位置会导致 `.dart_tool/package_config.json` 里的依赖路径失效（表现为找不到 `dio`、`riverpod` 等），执行 `flutter pub get` 修复；若编译报缺少 `build/native_assets/windows`，先建该目录再编译
- **归档**：`archive/` 存放探索性产物（逆向参考文档、残留日志）与说明 `README.md`，已排除静态分析；`test/`、`tool/` 下的测试和验证脚本已按整理要求删除（需要时可从 git 历史恢复）

## 已知问题：速读谷正文乱码（站点侧）

抓取 `div.con` 得到的是「UTF-8 字节被按 GBK 解读」后的混淆文本。已验证：

1. 换多种 UA（Chrome / Android / iPhone）→ 乱码一致
2. 带 Cookie 会话、补全 `Sec-Fetch-*` → 乱码一致
3. 本机 Chrome 无头模式真实渲染 → 浏览器看到的也是乱码

结论：混淆发生在服务端，信息在混淆过程中已丢失，无法无损还原。`utils/text_repair.dart` 的 GBK→UTF-8 逆向可恢复大部分汉字，但仍有约一成字符变成 `?`，因此默认只在检测到乱码时启用。待确认：混淆是否按出口 IP 地区分流。

## 历史排查记录（2026-11-08）

### 目录加载失败

- **现象**：详情页点「查看目录」报错或空白
- **根因**：速读谷目录共 5 页，站点从第 2 页起常返回 HTTP 200 的 404 页（gb2312）或直接 404；旧 `HttpClient` 将其视为致命异常，已解析的 1000 章全部丢弃
- **修复**：`validateStatus` 放行 + 浏览器请求头 + 请求重试；`loadToc` 每页最多重试 3 次、空页连续 2 次才停止、保留已抓章节并返回 `partial + warning`、页间 250ms 停顿、`pageUrlTemplate` 兜底翻页、`onProgress` 进度回调；`TocPage` 先渲染缓存再后台刷新、失败显示具体原因与重试按钮
- **验证**：曾用 `tool/verify_toc_local.dart` 回放真实目录页，6 项断言通过（该脚本现已在整理中删除，可从 git 恢复）

### receive timeout（连接建立但不吐数据）

- **现象**：`DioException [receive timeout]`，同一 URL 详情页请求成功、点目录再请求即挂起，判断为站点对短时间重复请求限速；170KB 页面在慢速网络下也会超时
- **修复**：引入 60 秒响应缓存（首屏 0 请求）；改为 `ResponseType.stream` 流式接收 + `idleTimeout` + `maxBytes`；`receiveTimeout` 放宽到 60s 仅作兜底；保留 3 天目录缓存
- **验证**：曾验证预热详情页 URL 后 `loadToc` 的 HTTP 请求数从 14 降到 13（脚本已删除）
