//
//  PythonBridge.m
//  按 beeware/Python-Apple-support USAGE.md 的「bare minimum」方式初始化解释器：
//  PYTHONHOME = <bundle>/python（prepare.sh 从 Python.xcframework 解出的标准库目录），
//  再通过 PyRun_SimpleString 执行引导脚本启动 app.start_server()。
//

#import "PythonBridge.h"
#include <Python/Python.h>

static BOOL sStarted = NO;

void shiguang_start_python(NSString *root, NSString *data) {
    if (sStarted) return;
    sStarted = YES;

    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    NSString *pythonHome = [resourcePath stringByAppendingPathComponent:@"python"];

    setenv("PYTHONHOME", pythonHome.fileSystemRepresentation, 1);
    setenv("SUDUGU_ROOT", root.fileSystemRepresentation, 1);
    setenv("SUDUGU_DATA", data.fileSystemRepresentation, 1);

    // 确保数据目录存在
    [[NSFileManager defaultManager] createDirectoryAtPath:data
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    // 初始化解释器（UTF-8 环境）
    setenv("LANG", [[NSString stringWithFormat:@"%@.UTF-8",
                     NSLocale.currentLocale.localeIdentifier] UTF8String], 1);
    Py_Initialize();

    // 引导脚本：设置 sys.path，导入 app，启动本地服务（start_server 内部自起服务线程）
    static const char *kBootstrap =
        "import os, sys, threading\n"
        "try:\n"
        "    root = os.environ['SUDUGU_ROOT']\n"
        "    data = os.environ['SUDUGU_DATA']\n"
        "    os.makedirs(data, exist_ok=True)\n"
        "    os.chdir(data)\n"
        "    sys.path.insert(0, root)\n"
        "    import app\n"
        "    app.start_server(host='127.0.0.1', port=8791)\n"
        "except BaseException:\n"
        "    import traceback\n"
        "    traceback.print_exc()\n"
        "    try:\n"
        "        p = os.path.join(os.environ.get('SUDUGU_DATA', '/'), 'boot_error.txt')\n"
        "        open(p, 'w', encoding='utf-8').write(traceback.format_exc())\n"
        "    except BaseException:\n"
        "        pass\n";

    PyRun_SimpleString(kBootstrap);

    // 释放主线程 GIL，让服务线程可以正常获取 GIL 运行
    PyEval_SaveThread();
}
