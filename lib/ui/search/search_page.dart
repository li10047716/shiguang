/// 搜索页：输入关键词 → 跳转聚合结果页
///
/// iOS 液态玻璃风格：渐变底 + 玻璃搜索框。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../glass.dart';
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
                  // 返回 + 搜索框 + 搜索按钮
                  Row(
                    children: [
                      IconButton(
                        tooltip: '返回',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Glass(
                          radius: 22,
                          blur: 18,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 2),
                          child: Row(
                            children: [
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
                                    hintText: '搜索书名 / 作者（聚合搜索全部书源）',
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
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 搜索按钮
                      Glass(
                        radius: 22,
                        blur: 18,
                        child: IconButton(
                          tooltip: '搜索',
                          icon: const Icon(Icons.arrow_forward,
                              color: Color(0xFF3E8EF7)),
                          onPressed: _go,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // 有历史：显示搜索历史；无历史：显示提示
                  if (_history.isNotEmpty)
                    Glass(
                      radius: 14,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('搜索历史',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                              const Spacer(),
                              IconButton(
                                tooltip: '清空历史',
                                icon: const Icon(Icons.delete_outline,
                                    size: 18, color: Colors.grey),
                                onPressed: _clearHistory,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final kw in _history)
                                ActionChip(
                                  label: Text(kw,
                                      style:
                                          const TextStyle(fontSize: 12)),
                                  onPressed: () {
                                    _controller.text = kw;
                                    _go();
                                  },
                                ),
                            ],
                          ),
                        ],
                      ),
                    )
                  else
                    Glass(
                      radius: 14,
                      blur: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.search,
                              size: 40, color: Colors.grey),
                          const SizedBox(height: 10),
                          const Text('输入关键词开始聚合搜索',
                              style: TextStyle(color: Colors.grey)),
                          const SizedBox(height: 6),
                          Text(
                            '会同时搜索所有已启用的书源，\n再按「书名 + 作者」聚合结果',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.grey.shade500, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
