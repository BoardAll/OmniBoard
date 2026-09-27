/// 全量路由表（《Flutter + C++ 工程结构设计》§3.1）。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'pages/board_edit_page.dart';
import 'pages/board_list_page.dart';
import 'pages/element_editor_page.dart';
import 'pages/settings_page.dart';

import 'services/board_file_service.dart';

/// 路由名与路径常量。
abstract final class WbRoutes {
  /// 白板列表（首页）。
  static const String boardList = 'boardList';

  /// 白板编辑页。
  static const String boardEdit = 'boardEdit';

  /// 设置页。
  static const String settings = 'settings';

  /// 专业元素独立编辑页（问题 6）：与「创建」共用，保存返回模型。
  static const String elementEditor = 'boardElementEditor';

  /// 首页路径。
  static const String homePath = '/';

  /// 设置页路径。
  static const String settingsPath = '/settings';

  /// 编辑页路径（带白板 id）。
  static String boardPath(String boardId) => '/board/$boardId';

  /// 元素编辑页路径（带白板 id；经 `extra` 传 [WbElementEditorRequest]）。
  static String elementEditorPath(String boardId) => '/board/$boardId/editor';
}

/// 构建应用路由。
GoRouter createRouter({String initialLocation = WbRoutes.homePath}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: WbRoutes.homePath,
        name: WbRoutes.boardList,
        builder: (BuildContext context, GoRouterState state) =>
            const BoardListPage(),
        routes: <RouteBase>[
          GoRoute(
            path: 'board/:boardId',
            name: WbRoutes.boardEdit,
            builder: (BuildContext context, GoRouterState state) {
              // 列表页「打开本地白板」经 extra 传 [WbBoardOpenRequest]。
              final Object? extra = state.extra;
              return BoardEditPage(
                boardId: state.pathParameters['boardId'] ?? '',
                boardName: state.uri.queryParameters['name'] ?? '',
                openFilePath:
                    extra is WbBoardOpenRequest ? extra.filePath : '',
              );
            },
          ),
          GoRoute(
            path: 'board/:boardId/editor',
            name: WbRoutes.elementEditor,
            builder: (BuildContext context, GoRouterState state) {
              final Object? extra = state.extra;
              if (extra is WbElementEditorRequest) {
                return ElementEditorPage(request: extra);
              }
              // 直接访问（无 extra）：提示后由用户返回画布重新打开。
              return const Scaffold(
                body: Center(child: Text('缺少编辑器参数，请返回画布重新打开')),
              );
            },
          ),
          GoRoute(
            path: 'settings',
            name: WbRoutes.settings,
            builder: (BuildContext context, GoRouterState state) =>
                const SettingsPage(),
          ),
        ],
      ),
    ],
  );
}
