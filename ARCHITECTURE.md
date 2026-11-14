# ReadingApp 架构设计

一款聚合阅读软件：小说（优先）→ 漫画 → 视频，采用**内置书源 + 规则引擎**方式，搜索结果为多源聚合展示。

## 技术选型

| 项 | 选择 | 说明 |
|---|---|---|
| 框架 | Flutter 3.47.9 | 跨平台（Android/iOS/Windows/macOS/Linux） |
| 语言 | Dart 3 | 空安全 |
| 网络 | dio | 支持拦截器、并发、取消 |
| HTML 解析 | html | CSS 选择器规则 |
| 状态管理 | riverpod | 搜索流、书架状态 |
| 本地存储 | isar / shared_preferences | 书架、阅读进度、书源配置 |
| 并发搜索 | Futures + 超时控制 | 每个书源独立超时，先到先展示 |

## 模块划分（lib/）

```
lib/
├── main.dart
├── models/
│   ├── book_source.dart    # 书源模型（JSON 规则）
│   ├── book.dart           # 书籍（聚合结果/书架书）
│   ├── chapter.dart        # 章节目录
│   └── content_type.dart   # novel / comic / video
├── sources/
│   ├── rule_engine.dart    # 规则解析核心（CSS/XPath/JSONPath/@get:）
│   ├── novel_source.dart   # 小说源执行器：search/detail/toc/content
│   ├── comic_source.dart   # 预留
│   ├── video_source.dart   # 预留
│   └── builtin/            # 内置书源 JSON 列表
├── services/
│   ├── http_client.dart    # dio 封装（UA、编码、重试）
│   ├── search_aggregator.dart  # 聚合搜索：并发+去重+进度流
│   └── library.dart        # 书架/历史存储
├── ui/
│   ├── search/
│   │   ├── search_page.dart        # 搜索框 + 历史
│   │   └── aggregate_result_page.dart # 聚合结果（按书聚合，展开看来源）
│   ├── book/
│   │   ├── book_detail_page.dart
│   │   └── toc_page.dart
│   ├── reader/
│   │   └── reader_page.dart        # 正文阅读（字号/背景/翻页）
│   └── shelf/
│       └── shelf_page.dart         # 书架
└── utils/
```

## 书源规则格式（JSON，类 Legado 风格）

```json
{
  "sourceName": "示例书源",
  "sourceUrl": "https://www.example.com",
  "sourceType": "novel",
  "enabled": true,
  "search": {
    "url": "https://www.example.com/search?q={{key}}&page={{page}}",
    "method": "GET",
    "bookList": "css: .result-item",
    "name": "css: h3 a@text",
    "author": "css: .author@text",
    "cover": "css: img@src",
    "bookUrl": "css: h3 a@href"
  },
  "detail": { "name": "...", "tocUrl": "..." },
  "toc": { "chapterList": "...", "chapterName": "...", "chapterUrl": "..." },
  "content": { "content": "css: #content@textNodes" }
}
```

规则语法：
- `css: <selector>@<attr|text|textNodes|html>` —— CSS 选择器
- `A || B` —— 回退链（列表页/详情页结构不同时兜底）
- `##正则##替换` —— 正则后处理（去 URL 锚点、去「作者：」前缀）
- `:contains(文字)` —— 按元素文本筛选（如「下一页」）
- `@html` —— 取 innerHTML 并把 `<br>` 转成换行（正文分段）
- `{{key}}` / `{{page}}` —— 搜索模板变量

已内置书源：
- 速读谷 `https://www.sudugu.cc`（杰奇 CMS）：搜索 `/modules/article/search.php?searchkey=&searchtype=all`；
  目录每页 1000 章，靠 `nextTocUrl` 翻页合并；正文分 3 页（`_2.html`），靠 `nextContentUrl` 合并。
  ⚠️ 该站正文在服务端被混淆（详见下方「已知问题」）。

## 聚合搜索流程

1. 输入关键词 → 取出所有 enabled 且 type=novel 的书源
2. 并发请求（每源超时 10s，并发上限 6）
3. 每个源返回后立即推入 Stream（先到先展示）
4. 按「书名+作者」归一化合并：同名书聚合为一条，展示来源数徽标
5. 点击条目 → 展开来源列表（可切换换源）；点击具体来源 → 详情页

## 里程碑

1. ✅ M0：环境搭建（Flutter SDK）
2. M1：书源引擎 + 2~3 个可用示例书源跑通搜索→正文
3. M2：聚合搜索 UI + 进度展示
4. M3：书架、阅读器设置
5. M4：漫画源扩展（图片列表阅读器）
6. M5：视频源扩展（播放器 + m3u8 解析）

## 已知问题

### 速读谷正文乱码（站点侧）
抓取 `div.con` 拿到的文本是「UTF-8 字节被按 GBK 解读」后的混淆文本，例如
`銆銆绗1绔 闄ㄨ惤鐨勭殑澶╂墠`。已做的验证：

1. 换多种 UA（Chrome / Android / iPhone）→ 乱码一致
2. 带 Cookie 会话、补全 Sec-Fetch 等浏览器请求头 → 乱码一致
3. 用本机 Chrome 无头模式真实渲染页面 → 浏览器看到的也是乱码

结论：混淆发生在服务端，不是客户端能解决的问题（信息在混淆过程中已丢失，无法无损还原）。
尝试过 `GBK 编码回字节 → UTF-8 解码` 的逆向（见 `lib/utils/text_repair.dart`），
只能恢复大部分汉字，仍有约 1 成字符变成 �，因此默认只在检测到乱码时才启用，
正常站点不受影响。

**待确认**：混淆可能是按出口 IP 地区分流的。若在国内网络下抓到的正文正常，
则该问题只出现在境外出口，应用本身无需改动。

## 目录加载失败的排查与修复（2026-11-08 晚）

### 现象
详情页点「查看目录」进不去 / 报错，目录列表出不来。

### 根因
速读谷目录分页是 `/1670/`、`/1670/2` … 共 5 页，但站点对第二页开始**经常返回
HTTP 200 的 404 页**（2KB，内容为 `404 - File or directory not found`，且是 gb2312），
或者直接 404 状态码。旧实现的 `HttpClient` 没有 `validateStatus`，
第 2 页一旦返回 404 就抛 `DioException`，**整个目录请求随之失败**——
第 1 页明明已经解析到 1000 章，却被这一个异常全部丢掉，用户看到的就是「加载不出来」。

### 修复
1. `HttpClient`
   - `validateStatus: (_) => true`，不再把 404 当致命错误，交由解析层判断
   - 增加 `Referer`、`Accept`、`Sec-Fetch-*` 等浏览器头（降低被反爬拦截概率）
   - 失败自动重试（默认 2 次，退避 400/800ms），超时放宽到 20s/25s
2. `NovelSourceEngine.loadToc`
   - 每页最多重试 3 次；**页面拿不到章节**被视为「空页」而不是异常
   - 连续 2 页没有章节才停止，已抓到的章节全部保留，并返回 `partial + warning`
   - 页间 250ms 停顿，减少被限流
   - 新增 `TocRule.pageUrlTemplate`（如 `{{bookUrl}}{{page}}`）：
     速读谷第 2 页之后不再输出分页区，用页码模板兜底继续翻页
   - `onProgress` 回调，UI 可显示「第 N 页 / 已取 M 章」
3. `TocPage`（UI）
   - 先读本地缓存立即渲染，再后台刷新；刷新失败保留缓存
   - 加载中显示进度；失败显示**具体原因** + 重试按钮（不再是空白/静默）
   - 章节名搜索、上次阅读位置高亮与「上次读」跳转
   - 目录缓存 3 天，存 `shared_preferences`（`lib/services/toc_cache.dart`）

### 验证
`dart run tool/verify_toc_local.dart`：本地起 HTTP 服务回放真实抓取的目录页，
5 项断言全部通过（第 1 页 1000 章、翻页到第 2 页 1179 章、模板兜底、URL 绝对化、无重复）。

## 第二轮：receive timeout（连接建立了但不吐数据）

### 现象
修复 404 之后仍失败，错误为：
`DioException [receive timeout]: The request took longer than 0:00:25 to receive data`
URL 是 `https://www.sudugu.cc/1670/` —— 也就是**目录首屏**。

### 分析
同一个 URL 在**详情页**请求时是成功的（详情页的简介/最新章节都显示正常），
紧接着点「查看目录」再次请求同一 URL 就被挂起。也就是说站点对**短时间内的重复请求**
做了限速/挂起处理（连接建立、响应头返回，但 body 迟迟不吐）。

同时该目录页有 170KB，慢速网络下 25s 收不完也会触发接收超时。

### 修复
1. **响应缓存**（`HttpClient`）：同一 GET URL 60 秒内直接返回上次结果。
   详情页刚抓过 `/1670/`，点「查看目录」时**不再发第二次请求**，从根上绕开限流。
2. **流式接收**（`ResponseType.stream`）：
   - 边收边累积，`idleTimeout`（目录 8s / 正文 10s）内没有新数据就用已收到的内容
   - 慢速但持续传输的场景不再被整体 receiveTimeout 打断
   - 收到 `maxBytes` 上限主动断开（目录 2MB、正文 2MB、搜索 3MB）
   - 截断的 HTML 交给 html 包容错解析，已到达的章节照样能取到
3. `receiveTimeout` 放宽到 60s（流式下仅作兜底），连接超时 20s。
4. 目录页 `TocPage` 仍保留本地目录缓存（3 天），网络彻底不可用时显示旧目录。

### 验证
`dart run tool/verify_toc_local.dart` 6 项断言全过，其中新增两项：
- 预热详情页 URL 后再 `loadToc`，HTTP 请求数从 14 降到 13（首屏 0 请求，命中缓存）
- 独立最小用例：同一 URL 连发两次，第二次实际请求数为 0
