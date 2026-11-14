/// 书源注册表：统一管理所有 [NovelSource]。
///
/// 混合架构的核心——规则引擎源（JSON）与硬编码源（native/ Dart 模块）
/// 都在这里注册，前端通过 [all] / [enabledOfType] 拿统一接口，不区分来源。
/// 对应 shiguang 的 `core.book()/chapter()` 按书号前缀分派。
library;

import '../models/book_source.dart';
import 'builtin/builtin_sources.dart';
import 'native/ali.dart';
import 'native/bc.dart';
import 'native/daren.dart';
import 'native/dq.dart';
import 'native/gsh.dart';
import 'native/huadudm.dart';
import 'native/kuaikan.dart';
import 'native/localbook.dart';
import 'native/mkz.dart';
import 'native/qm.dart';
import 'native/shuqi.dart';
import 'rule_source.dart';
import 'source.dart';

class SourceRegistry {
  SourceRegistry._() {
    _loadRuleSources();
    _loadNativeSources();
  }

  static final SourceRegistry _instance = SourceRegistry._();

  factory SourceRegistry() => _instance;

  final List<NovelSource> _sources = [];

  /// 规则引擎源：从 JSON 书源仓库加载
  void _loadRuleSources() {
    for (final bs in SourceRepository().all) {
      _sources.add(RuleSource(bs));
    }
  }

  /// 硬编码源：native/ 下的 Dart 模块（阶段 3+ 逐个注册）
  void _loadNativeSources() {
    _sources.add(QmSource());
    _sources.add(ShuqiSource());
    _sources.add(DqSource());
    _sources.add(BcSource());
    _sources.add(AliSource());
    _sources.add(MkzSource());
    _sources.add(GshSource());
    _sources.add(KuaikanSource());
    _sources.add(DarenSource());
    _sources.add(LocalBookSource());
    _sources.add(HuadudmSource());
  }

  /// 全部书源
  List<NovelSource> get all => List.unmodifiable(_sources);

  /// 是否启用：规则源看 SourceRepository 的 enabled；硬编码源始终启用
  bool _isEnabled(NovelSource s) {
    final bs = SourceRepository().byId(s.sourceId);
    return bs == null || bs.enabled;
  }

  /// 启用中的全部书源（任意类型）
  List<NovelSource> get enabled =>
      _sources.where(_isEnabled).toList();

  /// 启用中的某类型书源（硬编码源始终启用）
  List<NovelSource> enabledOfType(ContentType type) =>
      _sources.where((s) => s.type == type && _isEnabled(s)).toList();

  /// 按 sourceId 查找
  NovelSource? byId(String id) {
    for (final s in _sources) {
      if (s.sourceId == id) return s;
    }
    return null;
  }

  /// 重新加载（导入书源后调用）
  void reload() {
    _sources.clear();
    _loadRuleSources();
    _loadNativeSources();
  }
}
