/// Web 应用路由表（《Flutter + C++ 工程结构设计》§3.1）。
///
/// 与桌面端（apps/desktop）保持同一路径约定：`/`（列表）与
/// `/board/:boardId`（编辑）；Web 端暂不提供设置页（设置入口在
/// 编辑页 AppBar 以菜单形式提供）。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'pages/board_edit_page.dart';
import 'pages/board_list_page.dart';

/// 路由名与路径常量。
abstract final class WbWebRoutes {
  /// 白板列表（首页）。
  static const String boardList = 'boardList';

  /// 白板编辑页。
  static const String boardEdit = 'boardEdit';

  /// 首页路径。
  static const String homePath = '/';

  /// 编辑页路径（带白板 id 与可选名称查询参数）。
  static String boardPath(String boardId, {String name = ''}) {
    final String base = '/board/$boardId';
    if (name.isEmpty) {
      return base;
    }
    return '$base?name=${Uri.encodeComponent(name)}';
  }
}

/// 构建 Web 应用路由。
GoRouter createWebRouter({String initialLocation = WbWebRoutes.homePath}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: WbWebRoutes.homePath,
        name: WbWebRoutes.boardList,
        builder: (BuildContext context, GoRouterState state) =>
            const BoardListPage(),
        routes: <RouteBase>[
          GoRoute(
            path: 'board/:boardId',
            name: WbWebRoutes.boardEdit,
            builder: (BuildContext context, GoRouterState state) => BoardEditPage(
              boardId: state.pathParameters['boardId'] ?? '',
              boardName: state.uri.queryParameters['name'] ?? '',
            ),
          ),
        ],
      ),
    ],
  );
}
