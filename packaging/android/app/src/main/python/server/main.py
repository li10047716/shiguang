"""server.main —— APK 内的 Python 服务入口。

目录结构（由 packaging/android/sync_code.bat 从项目根目录同步生成）：
    server/app.py      主服务（原版 app.py）
    server/reader/     书源解析模块
    server/web/        前端静态文件

app.py 读取 SUDUGU_DATA 作为数据目录、dirname(app.py) 作为代码目录，
MainActivity 在启动时把 filesDir 传进来注入环境变量。
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)


def android_main(data_dir):
    os.environ["SUDUGU_DATA"] = data_dir
    os.environ["SUDUGU_EMBEDDED"] = "1"   # 内嵌 CPython 无系统 CA，用打包的 Mozilla CA 包
    import app
    app.serve_forever()
