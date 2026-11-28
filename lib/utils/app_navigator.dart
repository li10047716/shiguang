import 'package:flutter/material.dart';

/// 全局导航键：供无 BuildContext 的服务层（如 WebView 抓取）使用。
class AppNavigator {
  AppNavigator._();

  static final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
}
