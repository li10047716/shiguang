# iOS（ipa）打包 —— Git 云端构建方案

## 原理

ipa 必须由 macOS + Xcode 编译，本机（Windows）无法直接产出。本方案把项目推到
GitHub，用 **GitHub Actions 的 macOS 云端机器**自动编译出 ipa：

- 应用壳：Swift `AppDelegate`（WKWebView 全屏加载本地服务）+
  Objective-C `PythonBridge`（初始化内嵌 CPython）
- Python 运行时：[beeware/Python-Apple-support](https://github.com/beeware/Python-Apple-support)
  官方 iOS 版 CPython 3.13 xcframework（CI 时自动下载）
- 应用代码：原版 `app.py` + `reader/` + `web/` 原样打包进 app bundle，
  服务跑在手机本机（127.0.0.1:8791），**不依赖电脑**

## 构建步骤

1. 把整个项目推到 GitHub 仓库（main 分支）：

   ```bash
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```

2. 打开 GitHub 仓库页面 → **Actions** 标签 → 左侧
   **Build iOS IPA** → 右上 **Run workflow** → 运行
   （或直接打一个 `v1.0` 标签推送，自动触发）

3. 等构建完成（约 5~10 分钟），在该次运行页面底部
   **Artifacts** 下载 `ShiguangReader-ipa`，
   得到 `ShiguangReader-unsigned.ipa`（**未签名**）

## 安装到 iPhone（对未签名 ipa 签名）

未签名 ipa 不能直接装，选一种方式：

| 方式 | 说明 | 费用 |
| --- | --- | --- |
| **Sideloadly**（推荐） | 电脑装 sideloadly.io，连接 iPhone，拖入 ipa，填自己的 Apple ID 签名安装 | 免费，7 天有效期，到期重签 |
| **AltStore** | 手机+电脑配对后可自动续签 | 免费，7 天有效期 |
| 苹果开发者账号 | 在 CI 中配置证书后产出已签名 ipa | $99/年，可长期使用 |

## 工程结构

```
packaging/ios/
├── app/
│   ├── project.yml            # xcodegen 工程定义
│   ├── src/
│   │   ├── AppDelegate.swift  # 启动 Python 服务 + WKWebView 界面
│   │   ├── PythonBridge.h/.m  # CPython 初始化（PYTHONHOME=<bundle>/python）
│   │   ├── BridgingHeader.h
│   │   └── Info.plist         # xcodegen 生成
│   ├── Assets.xcassets/       # AppIcon（CI 用 sips 从 web/icon-256.png 放大生成）
│   ├── Resources/             # CI 生成：app/（应用代码）+ python/（标准库）
│   └── Frameworks/            # CI 生成：Python.xcframework
└── ci/prepare.sh              # 同步代码 + 下载 CPython 支持包 + 生成图标
```

- **书源请求失败**：iOS 内嵌 CPython 没有系统 CA 根证书，旧版所有 HTTPS 书源都会报
  证书校验失败；v1.1 起已打包 `certs/cacert.pem` 并通过 `SSL_CERT_FILE` 指定。
  若个别书源仍失败，搜索页顶部会列出「哪个源 + 具体错误」并带「重新搜索」按钮，
  一般是手机网络到该站点不通（例如需要代理的站点）。
- **手机适配**：窄屏（≤640px）自动切换底部标签栏布局，避开刘海与 Home 指示条
  （`viewport-fit=cover` + safe-area），阅读器控制面板改为全宽。

## 常见问题

- **构建失败**：打开 Actions 运行日志看红色步骤。最常见是
  Python-Apple-support 发布包结构变化（`ci/prepare.sh` 里已有目录结构
  调试输出），按输出调整查找规则即可。
- **装上后白屏/提示服务启动失败**：应用沙盒 `Documents/boot_error.txt`
  里是 Python 启动异常堆栈（Sideloadly 等工具的「查看容器文件」或
  iMazing 可以导出）。
- **书源访问**：手机网络环境与电脑不同，个别站点（如爱丽丝书屋需代理）
  在手机直连下可能打不开，属网络环境差异。
- **局域网模式仍然可用**：电脑 `start_lan.bat` + 手机 Safari「添加到主屏幕」
  的方案不受影响，两套方案可并存。
