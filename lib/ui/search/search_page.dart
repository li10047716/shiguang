/// 搜索页：输入关键词 → 跳转聚合结果页
///
/// iOS 液态玻璃风格：渐变底 + 玻璃搜索框。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../glass.dart';
import '../../sources/source_registry.dart';
import 'aggregate_result_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const _historyKey = 'search_history';

  final _controller = TextEditingController();
  final _focus = FocusNode();
  List<String> _history = [];

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
    // 输入时刷新「清空」按钮显隐
    _controller.addListener(() => setState(() {}));
    _loadHistory();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final sp = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _history = sp.getStringList(_historyKey) ?? const []);
    }
  }

  /// 保存一条历史：去重插到最前，最多 20 条
  Future<void> _saveHistory(String kw) async {
    final sp = await SharedPreferences.getInstance();
    final list = (sp.getStringList(_historyKey) ?? const []).toList()
      ..remove(kw)
      ..insert(0, kw);
    if (list.length > 20) list.removeRange(20, list.length);
    await sp.setStringList(_historyKey, list);
    if (mounted) setState(() => _history = list);
  }

  Future<void> _clearHistory() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_historyKey);
    if (mounted) setState(() => _history = []);
  }

  Future<void> _removeHistory(String kw) async {
    final sp = await SharedPreferences.getInstance();
    final list = (sp.getStringList(_historyKey) ?? const []).toList()
      ..remove(kw);
    await sp.setStringList(_historyKey, list);
    if (mounted) setState(() => _history = list);
  }

  /// 白色圆形按钮（返回 / 三点）
  Widget _roundBtn(IconData icon, String tip, VoidCallback onTap) {
    return Material(
      color: Colors.white.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 20, color: Colors.grey.shade800),
        ),
      ),
    );
  }

  /// 三点菜单：选择参与聚合搜索的书源（存本地，聚合器只搜选中的）
  Future<void> _showSourcePicker() async {
    // 只列出已启用的书源，勾选决定哪些参与本次搜索
    final sources = SourceRegistry().enabled;
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    // 从未设置过：默认全选所有启用源（避免首次保存空列表导致永远无结果）；
    // 设置过：严格按上次勾选
    final saved = sp.getStringList('search_source_ids');
    var selected = saved != null
        ? saved.toList()
        : sources.map((s) => s.sourceId).toList();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.78,
          ),
          child: Glass(
            radius: 24,
            blur: 8,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('选择搜索书源',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                    TextButton(
                      onPressed: () => setSheet(() =>
                          selected =
                              sources.map((s) => s.sourceId).toList()),
                      child:
                          const Text('全选', style: TextStyle(fontSize: 12)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final s in sources)
                        CheckboxListTile(
                          dense: true,
                          title: Text(s.sourceName,
                              style: const TextStyle(fontSize: 13)),
                          value: selected.contains(s.sourceId),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              if (!selected.contains(s.sourceId)) {
                                selected.add(s.sourceId);
                              }
                            } else {
                              selected.remove(s.sourceId);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      await sp.setStringList('search_source_ids', selected);
                      if (mounted) setState(() {});
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _go() {
    final kw = _controller.text.trim();
    if (kw.isEmpty) return;
    _saveHistory(kw);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => AggregateResultPage(keyword: kw)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(child: GlassBackground()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                children: [
                  // 返回 + 搜索框 + 三点(书源选择)
                  Row(
                    children: [
                      _roundBtn(
                          Icons.arrow_back, '返回',
                          () => Navigator.of(context).pop()),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          height: 44,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    Colors.black.withValues(alpha: 0.06),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              const SizedBox(width: 14),
                              const Icon(Icons.search,
                                  size: 20, color: Colors.grey),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _controller,
                                  focusNode: _focus,
                                  textInputAction: TextInputAction.search,
                                  onSubmitted: (_) => _go(),
                                  decoration: const InputDecoration(
                                    hintText: '搜索书名、作者',
                                    hintStyle:
                                        TextStyle(color: Colors.grey),
                                    border: InputBorder.none,
                                    isDense: true,
                                  ),
                                ),
                              ),
                              if (_controller.text.isNotEmpty)
                                IconButton(
                                  tooltip: '清空',
                                  icon: const Icon(Icons.clear,
                                      size: 18, color: Colors.grey),
                                  onPressed: () {
                                    _controller.clear();
                                    setState(() {});
                                  },
                                ),
                              const SizedBox(width: 6),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _roundBtn(Icons.more_vert, '选择搜索书源',
                          _showSourcePicker),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // 有历史：显示搜索历史；无历史：显示提示
                  if (_history.isNotEmpty) ...[
                    Row(
                      children: [
                        const Text('搜索历史',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                        const Spacer(),
                        TextButton(
                          onPressed: _clearHistory,
                          child: const Text('清除',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.redAccent)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // 左对齐（外层 Column 默认居中，Align 撑满后靠左）
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final kw in _history)
                            InputChip(
                              label: Text(kw,
                                  style: const TextStyle(fontSize: 12)),
                              onPressed: () {
                                _controller.text = kw;
                                _go();
                              },
                              onDeleted: () => _removeHistory(kw),
                              deleteIcon:
                                  const Icon(Icons.close, size: 14),
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.9),
                              side: BorderSide.none,
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
