/// 应用根组件：Provider 装配 + MaterialApp.router。
///
/// 另承担主窗口关闭拦截（X / Alt+F4）：`WbWindowService.initialize` 已
/// `setPreventClose(true)`，本组件经 [WindowListener] 接收 `onWindowClose`，
/// 委托 [WbAppExitService]：未保存改动时弹三选询问后再决定是否真正退出。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_canvas/services/canvas_engine.dart';
import 'package:window_manager/window_manager.dart';

import 'routes.dart';
import 'services/ai_service.dart';
import 'services/app_exit_service.dart';
import 'services/board_file_service.dart';
import 'services/canvas_engine.dart';
import 'services/ffi_service.dart';
import 'services/settings_store.dart';
import 'services/shortcut_service.dart';
import 'services/sync_service.dart';
import 'state/ai_state.dart';
import 'state/board_state.dart';
import 'state/page_state.dart';
import 'state/selection_state.dart';
import 'state/theme_state.dart';

/// 白板桌面应用根组件。
///
/// 服务与全局状态从 [main] 注入（可测试）；页面级状态（board/page/
/// selection/ai）在此创建，随应用生命周期存活。
///
/// 路由实例在 [State] 中只创建一次：`MaterialApp.router` 因主题通知
/// 重建时绝不能重新 `createRouter()`，否则 GoRouter 状态（导航栈）
/// 会被重置回 `initialLocation`（设置页被弹出等问题）。
class WhiteboardApp extends StatefulWidget {
  const WhiteboardApp({
    super.key,
    required this.ffiService,
    required this.themeState,
    required this.collabService,
    required this.shortcutService,
    this.settingsStore,
    this.boardFileService,
    this.router,
    this.windowDestroyer,
  });

  /// FFI 聚合服务。
  final WbFfiService ffiService;

  /// 主题状态（全局单例）。
  final WbThemeState themeState;

  /// 协同服务（全局单例）。
  final WbCollabService collabService;

  /// 快捷键服务（注册表）。
  final WbShortcutService shortcutService;

  /// 设置存储（null = 不挂载其 Provider；测试 / 独立预览）。
  final WbSettingsStore? settingsStore;

  /// 白板文件服务（null = 无保存 / 脏标记与关闭询问）。
  final WbBoardFileService? boardFileService;

  /// 路由（测试可注入；缺省使用 [createRouter]）。
  final GoRouter? router;

  /// 退出回调（测试注入；缺省 `setPreventClose(false)` + `close()`
  /// 标准关闭路径，退出即时）。
  final Future<void> Function()? windowDestroyer;

  @override
  State<WhiteboardApp> createState() => _WhiteboardAppState();
}

class _WhiteboardAppState extends State<WhiteboardApp> with WindowListener {
  /// 路由单例（主题通知重建不重置导航栈）。
  late final GoRouter _router = widget.router ?? createRouter();

  /// 退出编排（窗口关闭拦截与列表页「退出应用」按钮共用）。
  late final WbAppExitService _exitService = WbAppExitService(
    files: widget.boardFileService,
    windowDestroyer: widget.windowDestroyer,
  );

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  // ---- 主窗口关闭拦截 -------------------------------------------------------

  /// 窗口关闭请求（X / Alt+F4）：`setPreventClose` 已拦截原生关闭，
  /// 此处按未保存状态决定销毁或留在应用。
  @override
  void onWindowClose() {
    unawaited(handleWindowClose());
  }

  /// 关闭流程（widget 测试直接调用）：委托 [WbAppExitService.requestExit]，
  /// 未保存改动时弹三选，保存成功 / 不保存 → 退出；取消 / 保存失败 → 留在应用。
  @visibleForTesting
  Future<void> handleWindowClose() async {
    await _exitService.requestExit(
      _router.routerDelegate.navigatorKey.currentContext,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<WbFfiService>.value(value: widget.ffiService),
        Provider<WbCanvasEngine>(
          create: (BuildContext context) =>
              WbFfiCanvasEngine(widget.ffiService),
        ),
        Provider<WbShortcutService>.value(value: widget.shortcutService),
        Provider<WbAppExitService>.value(value: _exitService),
        ChangeNotifierProvider<WbThemeState>.value(value: widget.themeState),
        ChangeNotifierProvider<WbCollabService>.value(value: widget.collabService),
        if (widget.settingsStore != null)
          Provider<WbSettingsStore>.value(value: widget.settingsStore!),
        if (widget.boardFileService != null)
          ChangeNotifierProvider<WbBoardFileService>.value(
            value: widget.boardFileService!,
          ),
        ChangeNotifierProvider<WbBoardState>(
          create: (BuildContext context) => WbBoardState(ffi: widget.ffiService),
        ),
        ChangeNotifierProvider<WbPageState>(
          create: (BuildContext context) =>
              WbPageState(ops: WbFfiPageOps(widget.ffiService)),
        ),
        ChangeNotifierProvider<WbSelectionState>(
          create: (BuildContext context) => WbSelectionState(),
        ),
        ChangeNotifierProvider<WbAiState>(
          create: (BuildContext context) {
            final WbAiState state =
                WbAiState(aiService: WbAiAppService(ffi: widget.ffiService));
            // 启动恢复：上次在设置页「应用」过的 AI 配置（已落盘）。
            final WbAiSettings? ai = widget.settingsStore?.ai;
            if (ai != null) {
              state.configure(ai.build());
            }
            return state;
          },
        ),
      ],
      child: Consumer<WbThemeState>(
        builder: (BuildContext context, WbThemeState theme, Widget? child) {
          return MaterialApp.router(
            title: 'Whiteboard',
            debugShowCheckedModeBanner: false,
            theme: theme.flutterThemeData,
            routerConfig: _router,
          );
        },
      ),
    );
  }
}
