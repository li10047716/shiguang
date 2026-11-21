# 归档目录说明

本目录存放**探索性/逆向参考文档和历史日志**,不参与 App 构建,仅供回溯参考。

> 注:原先归档于此的效果验证页(`probes/glass_probe.dart`、`probes/shelf3d_probe.dart`)已按需求删除;如需找回,可从 git 历史中恢复(`git checkout HEAD~N -- lib/ui/glass_probe.dart`)。

## docs/ 参考文档

| 文件 | 原路径 | 作用 |
|---|---|---|
| `ios1114_bookshelf_reverse.md` | `docs/ios1114_bookshelf_reverse.md` | 从某 iOS 阅读 App 逆向出的书架 UI 复刻笔记(包名、类符号、资源清单) |
| `liquid_glass_easy_params.md` | `docs/liquid_glass_easy_params.md` | `liquid_glass_easy` 5.2.0 玻璃参数速查,对比当前 M3 实现与目标效果 |

## logs/ 历史日志

| 文件 | 原路径 | 作用 |
|---|---|---|
| `.old_job.log` | 项目根目录 | 一次 GitHub Actions 日志下载失败的残留响应(403),非业务文件 |

## 分析器配置

`analysis_options.yaml` 已将 `archive/**` 加入 `analyzer.exclude`,归档内容不参与 `flutter analyze`。
