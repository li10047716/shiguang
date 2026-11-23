/// 书源注册表：统一管理所有 [NovelSource]。
///
/// 小说书源注册表：规则引擎源与原生适配器统一由此管理。
/// 对应 shiguang 的 `core.book()/chapter()` 按书号前缀分派。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import 'builtin/builtin_sources.dart';
import 'native/ali.dart';
import 'native/bc.dart';
import 'native/dq.dart';
import 'native/ik8.dart';
import 'native/localbook.dart';
import 'native/qm.dart';
import 'native/shuqi.dart';
import 'rule_source.dart';
import 'source.dart';

class SourceRegistry with ChangeNotifier {
  SourceRegistry._() {
    _loadRuleSources();
    _loadNativeSources();
    _loadHardEnabled();
    _loadOrder();
  }

  static final SourceRegistry _instance = SourceRegistry._();

  factory SourceRegistry() => _instance;

  final List<NovelSource> _sources = [];

  /// 书源自定义顺序（sourceId 列表）。为空表示用默认注册顺序。
  List<String> _order = const [];
  static const _orderKey = 'source_order';

  /// 硬编码源（native/）的禁用集合：sourceId -> 是否禁用。
  /// 默认全部启用（含 ik8 爱看吧）；书源管理里可开关，持久化到 SharedPreferences。
  final Map<String, bool> _hardDisabled = {};

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
    _sources.add(LocalBookSource());
    _sources.add(Ik8Source()); // 爱看吧：默认开启
  }

  /// 异步加载硬编码源的启停状态（默认启用，不阻塞启动）
  void _loadHardEnabled() {
    SharedPreferences.getInstance().then((sp) {
      for (final s in _sources) {
        if (s.sourceId == 'loc') continue; // 本地源始终启用，不读禁用状态
        if (SourceRepository().byId(s.sourceId) == null) {
          final enabled = sp.getBool('source_enabled_${s.sourceId}') ?? true;
          if (!enabled) _hardDisabled[s.sourceId] = true;
        }
      }
    });
  }

  /// 异步加载自定义书源顺序（不阻塞启动）
  void _loadOrder() {
    SharedPreferences.getInstance().then((sp) {
      final saved = sp.getStringList(_orderKey);
      if (saved == null || saved.isEmpty) return;
      _order = saved;
      _applyOrder();
      notifyListeners();
    });
  }

  /// 按 _order 重排 _sources；未在顺序表里的源保持相对次序排在后面。
  void _applyOrder() {
    if (_order.isEmpty) return;
    final rank = <String, int>{};
    for (var i = 0; i < _order.length; i++) {
      rank[_order[i]] = i;
    }
    final sorted = <NovelSource>[];
    final seen = <String>{};
    for (final id in _order) {
      for (final s in _sources) {
        if (s.sourceId == id && !seen.contains(id)) {
          sorted.add(s);
          seen.add(id);
          break;
        }
      }
    }
    for (final s in _sources) {
      if (!seen.contains(s.sourceId)) sorted.add(s);
    }
    _sources
      ..clear()
      ..addAll(sorted);
  }

  /// 设置书源顺序：[ids] 为排好序的 sourceId 列表，持久化并通知刷新。
  Future<void> setOrder(List<String> ids) async {
    _order = List.of(ids);
    _applyOrder();
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_orderKey, ids);
    notifyListeners();
  }

  /// 全部书源
  List<NovelSource> get all => List.unmodifiable(_sources);

  /// 是否启用：规则源看 SourceRepository 的 enabled；硬编码源读持久化状态
  bool _isEnabled(NovelSource s) {
    // 本地导入源是内置功能，始终可用，避免误关后本地书打不开。
    if (s.sourceId == 'loc') return true;
    final bs = SourceRepository().byId(s.sourceId);
    if (bs != null) return bs.enabled;
    return !(_hardDisabled[s.sourceId] ?? false);
  }

  /// 公开的启用状态查询（供书源管理界面用，同步）
  bool isEnabled(String sourceId) {
    if (sourceId == 'loc') return true;
    final bs = SourceRepository().byId(sourceId);
    if (bs != null) return bs.enabled;
    return !(_hardDisabled[sourceId] ?? false);
  }

  /// 切换书源启用状态（持久化）。规则源走 SourceRepository，硬编码源走本地 prefs。
  /// 通知监听者（如发现页）刷新启用的书源列表。
  Future<void> toggleEnabled(String sourceId, bool enabled) async {
    if (SourceRepository().byId(sourceId) != null) {
      await SourceRepository().toggle(sourceId, enabled);
    } else {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('source_enabled_$sourceId', enabled);
      if (enabled) {
        _hardDisabled.remove(sourceId);
      } else {
        _hardDisabled[sourceId] = true;
      }
    }
    notifyListeners();
  }

  /// 启用中的全部书源（任意类型）
  List<NovelSource> get enabled =>
      _sources.where(_isEnabled).toList();

  /// 启用中的某类型书源
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
    _applyOrder();
    notifyListeners();
  }
}
