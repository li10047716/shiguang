//
//  PythonBridge.h
//  初始化内嵌 CPython 并启动拾光阅读器 HTTP 服务（后台线程）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// root: bundle 内 app/ 目录（app.py、reader/、web/ 所在地），对应 SUDUGU_ROOT
/// data: 沙盒 Documents 目录，对应 SUDUGU_DATA（书架/缓存持久化位置）
void shiguang_start_python(NSString *root, NSString *data);

NS_ASSUME_NONNULL_END
