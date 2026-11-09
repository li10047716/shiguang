"""拾光阅读器 —— 桌面 exe 版入口：内置本地服务 + Edge/Chrome 应用窗口。

用 PyInstaller 打包后是单个 exe：双击启动内置服务并弹出应用窗口，
不依赖 Python 环境。相比 pywebview 方案，这里直接复用 Edge/Chrome 的
--app 模式，不挑 WebView2 运行时版本，兼容老电脑。
数据（书架/进度/缓存）保存在 exe 旁边的 data\ 目录里。
"""
import os
import sys

# 打包成 exe 后，数据目录放在 exe 旁边，跟代码目录（临时解压目录）分离
if getattr(sys, "frozen", False):
    os.environ.setdefault(
        "SUDUGU_DATA",
        os.path.join(os.path.dirname(os.path.abspath(sys.executable)), "data"),
    )
    base = sys._MEIPASS  # PyInstaller 解压目录（内含 web/ reader/ app.py）
else:
    base = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, base)

import app  # noqa: E402

if __name__ == "__main__":
    app.main()  # 启动服务 → 打开 Edge 应用窗口 → 看门狗守护
