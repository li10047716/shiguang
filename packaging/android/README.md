# Android APK 构建说明

原理：[Chaquopy](https://chaquo.com/chaquopy/) 在 APK 里内嵌真实 CPython，
跑的就是原版 Python 服务（全部 8 个书源解析原样可用），WebView 加载本机服务。

## 前置条件

1. **Android Studio**（Hedgehog/Iguana 及以上，自带 JDK 17）
2. 本机装有 **Python 3.8+**（Chaquopy 构建期要用；若不在 PATH，
   在 `app/build.gradle` 的 `python { buildPython "..." }` 里填完整路径）

## 构建步骤

1. 双击 `sync_code.bat` —— 把项目根目录最新的 app.py / reader / web 同步进安卓工程
   （以后每次改完阅读器代码，都要先跑这一步再重新打包）
2. 用 Android Studio 打开本目录（packaging/android），等待 Gradle 同步完成
   （首次会自动下载 Gradle 8.4、AGP 8.1.4、Chaquopy 15.0.1 和 Python 运行时，需要网络）
3. 菜单 Build → Build Bundle(s)/APK(s) → Build APK(s)
4. 产物在 `app/build/outputs/apk/debug/app-debug.apk`，传到手机安装即可

## 说明

- 数据（书架/缓存）存在应用私有目录（filesDir），卸载即清空
- 首次安装的默认图标是系统占位图标，想要自定义图标可在
  `app/src/main/res/mipmap-*/ic_launcher.png` 放入各尺寸图标
- debug 包可直接安装；要发正式版需自己生成签名 keystore（Build → Generate Signed APK）
- APK 体积约 25~40MB（含 Python 运行时 + 两个 CPU 架构）

## 已知限制

- 部分书源站点在手机网络环境下可能需要代理才能访问（与电脑上同源同规则）
- 未做横屏适配锁定了转屏不重建（WebView 不会因旋转丢进度）
