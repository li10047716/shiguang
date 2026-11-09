#!/bin/bash
# 在 macOS（本地或 GitHub Actions）上运行：
#   bash packaging/ios/ci/prepare.sh
# 作用：
#   1. 把仓库里的应用代码（app.py / reader/ / web/）同步进 Xcode 资源目录
#   2. 下载 beeware Python-Apple-support 的 iOS CPython 支持包，
#      解出 Python.xcframework（链接/嵌入用）和标准库目录（bundle 内 python/，即 PYTHONHOME）
#   3. 由 web/icon-256.png 生成 1024 AppIcon
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP_DIR="$REPO_ROOT/packaging/ios/app"
RES="$APP_DIR/Resources"
FRAMEWORKS="$APP_DIR/Frameworks"
PY_TAG="3.13-b12"
PY_URL="https://github.com/beeware/Python-Apple-support/releases/download/$PY_TAG/Python-3.13-iOS-support.b12.tar.gz"

echo "==> [1/4] 同步应用代码"
rm -rf "$RES/app"
mkdir -p "$RES/app"
cp "$REPO_ROOT/app.py" "$RES/app/"
cp "$REPO_ROOT/certs/cacert.pem" "$RES/app/cacert.pem"   # iOS 无系统 CA，HTTPS 书源要用
cp -R "$REPO_ROOT/reader" "$RES/app/reader"
find "$RES/app" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
cp -R "$REPO_ROOT/web" "$RES/app/web"

echo "==> [2/4] 下载并解包 CPython 支持包 ($PY_TAG)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fL --retry 3 -o "$TMP/python-ios.tar.gz" "$PY_URL"
mkdir -p "$TMP/extract"
tar -xzf "$TMP/python-ios.tar.gz" -C "$TMP/extract"
echo "    解包结构："
find "$TMP/extract" -maxdepth 4 | head -40

echo "==> [3/4] 安装 Python.xcframework 与标准库"
rm -rf "$FRAMEWORKS" "$RES/python"
mkdir -p "$FRAMEWORKS"

XCFRAMEWORK="$(find "$TMP/extract" -type d -name "Python.xcframework" -maxdepth 3 | head -1)"
if [ -z "$XCFRAMEWORK" ]; then
    echo "错误：解包结果里找不到 Python.xcframework（上面已打印目录结构）" >&2
    exit 1
fi
rm -rf "$FRAMEWORKS/Python.xcframework"
cp -R "$XCFRAMEWORK" "$FRAMEWORKS/Python.xcframework"
# 真机 ipa 不需要模拟器切片和构建辅助文件
rm -rf "$FRAMEWORKS/Python.xcframework/ios-arm64_x86_64-simulator" \
       "$FRAMEWORKS/Python.xcframework/build"

# PYTHONHOME = 真机切片根目录（内含 lib/python3.13 与 Python.framework）
PYHOME_SRC="$FRAMEWORKS/Python.xcframework/ios-arm64"
if [ ! -d "$PYHOME_SRC/lib/python3.13" ]; then
    echo "错误：$PYHOME_SRC/lib/python3.13 不存在，支持包结构可能变化" >&2
    exit 1
fi
rm -rf "$RES/python"
mkdir -p "$RES"
# 标准库运行时不需要交叉编译工具链和头文件
cp -R "$PYHOME_SRC" "$RES/python"
rm -rf "$RES/python/bin" "$RES/python/include"
echo "    PYTHONHOME: $PYHOME_SRC"
ls "$RES/python"

echo "==> [4/4] 生成 AppIcon（1024）"
ICON_DIR="$APP_DIR/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICON_DIR"
sips -z 1024 1024 "$REPO_ROOT/web/icon-256.png" --out "$ICON_DIR/icon-1024.png" >/dev/null

echo "==> 准备完成"
