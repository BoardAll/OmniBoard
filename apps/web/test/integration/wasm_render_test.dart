/// apps/web WASM 集成测试（《测试方案设计》§7.3）—— 渲染路径与显示列表。
///
/// VM 环境没有真实 wasm，本文件白盒验证渲染侧的降级契约：
/// - 核心不可用时编辑页降级到内置演示画布（`wb-demo-canvas`）与提示条；
/// - [WbCoreService] 注入驱动状态 chip 的三态展示
///   （引擎待命 / 引擎就绪 / 演示画布）；
/// - [WbCoreModule] 的显示列表读取接口（`readBytes`）与常量化占位形状。
///
/// 真实渲染显示列表（WASM 线性内存中的 draw list）由 C++ 侧与
/// 浏览器链路覆盖；此处仅验证 Dart 侧接口在缺失产物时安全降级。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_web/app.dart';
import 'package:whiteboard_web/routes.dart';
import 'package:whiteboard_web/services/wb_core_service.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

void main() {
  group('编辑页降级渲染（真实桩服务）', () {
    testWidgets('核心不可用 → 演示画布 + 降级提示条 + 状态 chip', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        WhiteboardWebApp(
          router: createWebRouter(
            initialLocation: WbWebRoutes.boardPath('render-fallback'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 画布区：演示画布 + 降级提示条（不阻塞 UI）。
      expect(find.byKey(const Key('wb-demo-canvas')), findsOneWidget);
      expect(find.textContaining('内置演示画布'), findsOneWidget);
      // AppBar 状态 chip：不可用 → '演示画布'。
      expect(find.text('演示画布'), findsOneWidget);
      expect(
        find.byTooltip('WASM 核心不可用（占位脚本），当前为内置演示画布'),
        findsOneWidget,
      );
      // 宽屏布局：左侧工具面板可见（降级不影响工具展示）。
      expect(find.text('工具'), findsOneWidget);
    });
  });

  group('状态 chip 三态（注入 fake coreService）', () {
    Future<void> pumpWithStatus(WidgetTester tester, WbCoreStatus status) async {
      final WbCoreService service =
          WbCoreService(loader: _PinnedLoader(status));
      addTearDown(service.dispose);
      await tester.pumpWidget(
        WhiteboardWebApp(
          router: createWebRouter(
            initialLocation: WbWebRoutes.boardPath('chip-${status.id}'),
          ),
          coreService: service,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('idle：引擎待命，无降级提示条', (WidgetTester tester) async {
      await pumpWithStatus(tester, WbCoreStatus.idle);
      expect(find.text('引擎待命'), findsOneWidget);
      expect(find.textContaining('内置演示画布'), findsNothing);
      expect(find.byKey(const Key('wb-demo-canvas')), findsOneWidget);
    });

    testWidgets('ready：引擎就绪，ccall / cwrap 可用提示', (WidgetTester tester) async {
      await pumpWithStatus(tester, WbCoreStatus.ready);
      expect(find.text('引擎就绪'), findsOneWidget);
      expect(find.byTooltip('WASM 核心已加载：ccall / cwrap 可用'), findsOneWidget);
      expect(find.textContaining('内置演示画布'), findsNothing);
    });

    testWidgets('unavailable：演示画布 chip + 降级提示条', (WidgetTester tester) async {
      await pumpWithStatus(tester, WbCoreStatus.unavailable);
      expect(find.text('演示画布'), findsOneWidget);
      expect(find.textContaining('内置演示画布'), findsOneWidget);
    });
  });

  group('WbCoreModule 显示列表接口（占位形状）', () {
    test('readBytes 恒返回空字节列表（无线性内存视图）', () {
      const WbCoreModule module = WbCoreModule.unsupported;
      expect(module.readBytes(0, 0), isEmpty);
      expect(module.readBytes(4096, 256), isEmpty);
      expect(module.readBytes(4096, 256), isA<Uint8List>());
    });

    test('unsupported 为 const 单例（可安全共享）', () {
      expect(
        identical(WbCoreModule.unsupported, WbCoreModule.unsupported),
        isTrue,
      );
    });
  });
}

/// 固定状态的 fake 加载器：`load()` 不改变状态（模拟注入后即稳定的场景）。
class _PinnedLoader extends WbCoreLoader {
  _PinnedLoader(this._status);

  final WbCoreStatus _status;

  @override
  WbCoreStatus get status => _status;

  @override
  bool get isAvailable => _status.isAvailable;

  @override
  Future<WbCoreStatus> load() async => _status;
}
