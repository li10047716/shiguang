/// 用系统 WebView 渲染需要执行 JavaScript 的页面，并返回渲染后的 HTML。
/// 不支持的平台（如 Windows/Linux）会抛出明确错误。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../utils/app_navigator.dart';

class WebViewFetch {
  static Future<String> html(
    String url, {
    Map<String, String> headers = const {},
    String? javascript,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final supported = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    if (!supported) {
      throw UnsupportedError('当前平台不支持 WebView 书源');
    }
    final ctx = AppNavigator.key.currentContext;
    if (ctx == null) throw StateError('应用尚未就绪，无法启动 WebView');
    final result = await Navigator.of(ctx).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => _WebViewFetchPage(
          url: url,
          headers: headers,
          javascript: javascript,
        ),
      ),
    );
    if (result == null) throw TimeoutException('WebView 页面加载超时或失败');
    return result;
  }
}

class _WebViewFetchPage extends StatefulWidget {
  const _WebViewFetchPage({
    required this.url,
    required this.headers,
    this.javascript,
  });

  final String url;
  final Map<String, String> headers;
  final String? javascript;

  @override
  State<_WebViewFetchPage> createState() => _WebViewFetchPageState();
}

class _WebViewFetchPageState extends State<_WebViewFetchPage> {
  late final WebViewController _controller;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _finish(),
        ),
      )
      ..loadRequest(Uri.parse(widget.url), headers: widget.headers);
    Future.delayed(const Duration(seconds: 25), _finish);
  }

  Future<void> _finish() async {
    if (_done || !mounted) return;
    _done = true;
    try {
      if (widget.javascript != null && widget.javascript!.isNotEmpty) {
        await _controller.runJavaScript(widget.javascript!);
      }
      final html = await _controller.runJavaScriptReturningResult(
        'document.documentElement.outerHTML',
      );
      if (!mounted) return;
      Navigator.of(context).pop(html.toString());
    } catch (_) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    body: SizedBox(
      width: 1,
      height: 1,
      child: WebViewWidget(controller: _controller),
    ),
  );
}
