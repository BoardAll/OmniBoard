/// 应用根组件：Provider 装配 + MaterialApp.router。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'routes.dart';
import 'services/wb_core_service.dart';
import 'state/theme_state.dart';

/// 白板 Web 应用根组件。
///
/// [router] / [themeState] / [coreService] 可注入（测试用）；
/// 缺省自建并随组件销毁（注入对象由调用方负责释放）。
class WhiteboardWebApp extends StatefulWidget {
  /// 创建应用。
  const WhiteboardWebApp({
    super.key,
    this.router,
    this.themeState,
    this.coreService,
  });

  /// 路由（缺省 [createWebRouter]）。
  final GoRouter? router;

  /// 主题状态。
  final WbWebThemeState? themeState;

  /// WASM 核心服务。
  final WbCoreService? coreService;

  @override
  State<WhiteboardWebApp> createState() => _WhiteboardWebAppState();
}

class _WhiteboardWebAppState extends State<WhiteboardWebApp> {
  late final WbWebThemeState _themeState =
      widget.themeState ?? WbWebThemeState();
  late final WbCoreService _coreService =
      widget.coreService ?? WbCoreService();
  late final GoRouter _router = widget.router ?? createWebRouter();

  @override
  void dispose() {
    if (widget.themeState == null) {
      _themeState.dispose();
    }
    if (widget.coreService == null) {
      _coreService.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<WbWebThemeState>.value(value: _themeState),
        ChangeNotifierProvider<WbCoreService>.value(value: _coreService),
      ],
      child: Consumer<WbWebThemeState>(
        builder: (BuildContext context, WbWebThemeState theme, Widget? child) {
          return MaterialApp.router(
            title: 'Whiteboard 白板',
            debugShowCheckedModeBanner: false,
            theme: theme.flutterThemeData,
            routerConfig: _router,
          );
        },
      ),
    );
  }
}
