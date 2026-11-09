# 打包目录总览

| 目标 | 状态 | 说明 |
| --- | --- | --- |
| Windows EXE | ✅ 已验证可用 | `exe/`，PyInstaller 单文件，双击即用 |
| Android APK | 📦 工程就绪 | `android/`，Chaquopy 内嵌 Python，Android Studio 构建 |
| iOS ipa | 🚧 云端可打 | `ios/`，推到 GitHub 后由 Actions 的 macOS 机器自动编译未签名 ipa（见 `ios/README.md`），Sideloadly 签名安装；局域网模式仍是零成本替代 |

## 共同基础

- `app.py` 重构后支持环境变量：
  - `SUDUGU_ROOT`：代码根目录（默认 = app.py 所在目录）
  - `SUDUGU_DATA`：数据目录（默认 = ROOT/data；exe 放 exe 旁，apk 放应用私有目录）
  - `SUDUGU_LAN=1`：监听 0.0.0.0，允许局域网设备访问
- `app.start_server(host)` / `app.serve_forever()`：无窗口常驻入口，供各打包宿主调用
