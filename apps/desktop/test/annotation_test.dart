/// 透明批注（Wave3-3.7）状态 / 控制器 / UI 测试。
///
/// 对照《透明批注模式技术方案》§4-§9：
/// - §4 两种状态与切换（含按住 Alt 临时穿透）；
/// - §5 进入 / 退出与退出三选项弹窗；
/// - §6 绘制 / 擦除 / 激光笔生命周期 / 撤销重做；
/// - §9 工具栏（工具选择、调色板、折叠、穿透徽标、半透明）；
/// - §10 全局快捷键注册约定与失败降级。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/platform/transparent_overlay_service.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/shortcut_service.dart';
import 'package:whiteboard_desktop/widgets/annotation/annotation.dart';
import 'package:whiteboard_theme/theme.dart';

/// 演示模式 FFI（加载必然失败，验证引擎提交点降级）。
WbFfiService _demoFfi() => WbFfiService(
      candidatePaths: const <String>['__wb_missing__.dll'],
    )..initialize();

/// 记录型全局热键注册器（可模拟平台失败 / 抛异常）。
class _RecordingRegistrar {
  _RecordingRegistrar({this.fail = false, this.raise = false});

  /// 返回 null（模拟平台不可用）。
  bool fail;

  /// 直接抛出（模拟注册通道异常）。
  bool raise;

  int registerCalls = 0;
  int unregisterCalls = 0;
  WbShortcut? lastShortcut;
  VoidCallback? trigger;

  Future<WbAnnotationHotkey?> call(
    WbShortcut shortcut,
    VoidCallback onTrigger,
  ) async {
    registerCalls++;
    lastShortcut = shortcut;
    trigger = onTrigger;
    if (raise) {
      throw StateError('平台通道不可用');
    }
    if (fail) {
      return null;
    }
    return WbAnnotationHotkey(unregister: () async {
      unregisterCalls++;
    });
  }
}

/// 故意抛错的覆盖层服务（窗口能力缺失 → 控制器降级路径）。
class _BrokenOverlayService extends WbTransparentOverlayService {
  int enterCalls = 0;
  int exitCalls = 0;

  @override
  Future<void> enter() async {
    enterCalls++;
    throw StateError('窗口服务不可用');
  }

  @override
  Future<void> exit() async {
    exitCalls++;
    throw StateError('窗口服务不可用');
  }
}

/// 在 1280×800 标准测试面挂载批注组合层。
Future<void> _pumpLayer(
  WidgetTester tester,
  WbAnnotationController controller,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: WbBuiltinThemes.defaultTheme.toFlutterThemeData(),
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[AnnotationLayer(controller: controller)],
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WbAnnotationState（纯逻辑）', () {
    test('进入 / 切换 / 退出状态机（§4）', () {
      final WbAnnotationState state = WbAnnotationState();
      expect(state.mode, WbAnnotationMode.off);
      expect(state.isActive, isFalse);

      state.enter();
      expect(state.mode, WbAnnotationMode.annotating);
      expect(state.isActive, isTrue);
      expect(state.isPenetrating, isFalse);

      state.setMode(WbAnnotationMode.penetrating);
      expect(state.isPenetrating, isTrue);

      state.setMode(WbAnnotationMode.annotating);
      expect(state.mode, WbAnnotationMode.annotating);

      // 未进入时 setMode 忽略（off 不作为目标态）。
      state.exit();
      expect(state.mode, WbAnnotationMode.off);
      state.setMode(WbAnnotationMode.penetrating);
      expect(state.mode, WbAnnotationMode.off);

      state.dispose();
    });

    test('笔迹创建与工具属性换算（§6.1 / §6.2）', () {
      final WbAnnotationState state = WbAnnotationState();
      state.setColor(WbAnnotationPalette.colors[4]);
      state.setWidth(WbAnnotationPalette.widths[2]);

      state.beginStroke(const Offset(0, 0));
      state.extendStroke(const Offset(10, 10));
      state.endStroke();
      final WbAnnotationStroke pen = state.strokes.single;
      expect(pen.tool, WbAnnotationTool.pen);
      expect(pen.color, WbAnnotationPalette.colors[4]);
      expect(pen.width, WbAnnotationPalette.widths[2]);
      expect(pen.opacity, 1);
      expect(pen.points.length, 2);

      state.selectTool(WbAnnotationTool.highlighter);
      state.beginStroke(const Offset(0, 0));
      state.endStroke();
      final WbAnnotationStroke highlighter = state.strokes.last;
      expect(highlighter.tool, WbAnnotationTool.highlighter);
      expect(
        highlighter.width,
        WbAnnotationPalette.widths[2] * WbAnnotationState.highlighterWidthRatio,
      );
      expect(highlighter.opacity, WbAnnotationState.highlighterOpacity);

      state.selectTool(WbAnnotationTool.laser);
      state.beginStroke(const Offset(0, 0));
      state.endStroke();
      final WbAnnotationStroke laser = state.strokes.last;
      expect(laser.isLaser, isTrue);
      expect(laser.color, WbAnnotationPalette.laser);
      expect(laser.width, WbAnnotationState.laserWidth);
      expect(WbAnnotationTool.eraser.drawsStroke, isFalse);

      state.dispose();
    });

    test('橡皮按线段命中擦除（§6.1）', () {
      final WbAnnotationState state = WbAnnotationState();
      state.beginStroke(const Offset(0, 0));
      state.extendStroke(const Offset(100, 0));
      state.endStroke();

      // 远离线段 → 不命中。
      expect(state.eraseAt(const Offset(50, 50)), 0);
      expect(state.strokeCount, 1);
      // 线段中部（非端点）→ 命中（点到线段距离判定）。
      expect(state.eraseAt(const Offset(50, 0)), 1);
      expect(state.strokeCount, 0);

      state.dispose();
    });

    test('撤销 / 重做 / 清空（§6.3）', () {
      final WbAnnotationState state = WbAnnotationState();
      state.beginStroke(const Offset(0, 0));
      state.endStroke();
      state.beginStroke(const Offset(5, 5));
      state.endStroke();
      expect(state.strokeCount, 2);

      expect(state.canUndo, isTrue);
      expect(state.undo(), isTrue);
      expect(state.strokeCount, 1);
      expect(state.canRedo, isTrue);
      expect(state.redo(), isTrue);
      expect(state.strokeCount, 2);

      state.clear();
      expect(state.strokeCount, 0);
      expect(state.canUndo, isFalse);
      expect(state.canRedo, isFalse);

      state.dispose();
    });

    test('激光笔生命周期：渐隐 / 过期 / 可见过滤（§6.1）', () {
      final DateTime t0 = DateTime(2026, 1, 1, 12);
      final WbAnnotationState state = WbAnnotationState()
        ..selectTool(WbAnnotationTool.laser);
      final String id = state.beginStroke(const Offset(0, 0), now: t0);
      expect(id, isNotEmpty);

      final WbAnnotationStroke stroke = state.strokes.single;
      expect(stroke.opacityAt(t0), 1);

      // 剩余 250ms（< 渐隐 500ms）→ 已开始渐隐。
      final DateTime late = t0.add(
        WbAnnotationStroke.laserLifespan - const Duration(milliseconds: 250),
      );
      final double faded = stroke.opacityAt(late);
      expect(faded, lessThan(1));
      expect(faded, greaterThan(0));

      // 到达寿命 → 过期、透明、不可见、可清理。
      final DateTime expired = t0.add(WbAnnotationStroke.laserLifespan);
      expect(stroke.isExpiredAt(expired), isTrue);
      expect(stroke.opacityAt(expired), 0);
      expect(state.visibleStrokes(expired), isEmpty);
      expect(state.purgeExpiredLaser(expired), isTrue);
      expect(state.strokeCount, 0);
      expect(state.purgeExpiredLaser(expired), isFalse);

      state.dispose();
    });

    test('markSaved 快照化（排除激光笔）/ 丢弃（§5.4 / §6.3）', () {
      final WbAnnotationState state = WbAnnotationState();
      state.beginStroke(const Offset(0, 0));
      state.endStroke();
      state.selectTool(WbAnnotationTool.laser);
      state.beginStroke(const Offset(1, 1));
      state.endStroke();
      expect(state.strokeCount, 2);

      state.markSaved();
      expect(state.strokeCount, 0);
      expect(state.savedCount, 1);
      expect(state.savedSnapshot.single.tool, WbAnnotationTool.pen);

      state.beginStroke(const Offset(2, 2));
      state.endStroke();
      state.discardStrokes();
      expect(state.strokeCount, 0);
      expect(state.hasStrokes, isFalse);

      state.dispose();
    });
  });

  group('WbAnnotationController（编排与降级）', () {
    test('enter 编排：状态 + 覆盖层 + 快捷键注册（幂等）', () async {
      final WbTransparentOverlayService overlay =
          WbTransparentOverlayService();
      final _RecordingRegistrar registrar = _RecordingRegistrar();
      final WbAnnotationController controller = WbAnnotationController(
        overlay: overlay,
        hotkeyRegistrar: registrar.call,
      );
      addTearDown(() {
        controller.dispose();
        overlay.dispose();
      });

      await controller.enter();
      expect(controller.isActive, isTrue);
      expect(controller.mode, WbAnnotationMode.annotating);
      expect(overlay.isActive, isTrue);
      expect(registrar.registerCalls, 1);
      expect(registrar.lastShortcut?.id, 'annotate.toggleTransparent');
      expect(registrar.lastShortcut?.scope, WbShortcutScope.global);
      expect(controller.shortcutRegistered, isTrue);

      await controller.enter();
      expect(registrar.registerCalls, 1);
    });

    test('exit 编排：注销快捷键 + 还原覆盖层', () async {
      final WbTransparentOverlayService overlay =
          WbTransparentOverlayService();
      final _RecordingRegistrar registrar = _RecordingRegistrar();
      final WbAnnotationController controller = WbAnnotationController(
        overlay: overlay,
        hotkeyRegistrar: registrar.call,
      );
      addTearDown(() {
        controller.dispose();
        overlay.dispose();
      });

      await controller.enter();
      await controller.exit();
      expect(controller.isActive, isFalse);
      expect(controller.mode, WbAnnotationMode.off);
      expect(controller.shortcutRegistered, isFalse);
      expect(registrar.unregisterCalls, 1);
      expect(overlay.phase, WbOverlayPhase.off);
    });

    test('全局快捷键触发穿透切换（双通道之快捷键）', () async {
      final _RecordingRegistrar registrar = _RecordingRegistrar();
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: registrar.call,
      );
      addTearDown(controller.dispose);

      await controller.enter();
      expect(controller.isPenetrating, isFalse);

      registrar.trigger!();
      await Future<void>.delayed(Duration.zero);
      expect(controller.isPenetrating, isTrue);

      registrar.trigger!();
      await Future<void>.delayed(Duration.zero);
      expect(controller.mode, WbAnnotationMode.annotating);
    });

    test('注册返回 null：静默降级，工具栏通道仍可用（§10）', () async {
      final _RecordingRegistrar registrar = _RecordingRegistrar(fail: true);
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: registrar.call,
      );
      addTearDown(controller.dispose);

      await controller.enter();
      expect(controller.isActive, isTrue);
      expect(controller.shortcutRegistered, isFalse);
      expect(controller.shortcutStatus, contains('降级'));
      expect(controller.lastError, isEmpty);

      await controller.togglePenetrate();
      expect(controller.isPenetrating, isTrue);
    });

    test('注册器抛异常：捕获并记录，不崩溃', () async {
      final _RecordingRegistrar registrar = _RecordingRegistrar(raise: true);
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: registrar.call,
      );
      addTearDown(controller.dispose);

      await controller.enter();
      expect(controller.isActive, isTrue);
      expect(controller.shortcutRegistered, isFalse);
      expect(controller.lastError, contains('全局快捷键注册失败'));
    });

    test('覆盖层服务异常：UI 状态切换不受影响（降级）', () async {
      final _BrokenOverlayService overlay = _BrokenOverlayService();
      final WbAnnotationController controller = WbAnnotationController(
        overlay: overlay,
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);

      await controller.enter();
      expect(overlay.enterCalls, 1);
      expect(controller.isActive, isTrue);
      expect(controller.lastError, contains('降级'));

      await controller.exit();
      expect(overlay.exitCalls, 1);
      expect(controller.isActive, isFalse);
      expect(controller.lastError, contains('还原失败'));
    });

    test('默认注册器在无平台环境静默降级（不触发插件）', () async {
      final WbAnnotationController controller = WbAnnotationController();
      addTearDown(controller.dispose);

      await controller.enter();
      expect(controller.isActive, isTrue);
      expect(controller.shortcutRegistered, isFalse);
      // 静默：测试 / 演示环境不产生错误。
      expect(controller.lastError, isEmpty);

      await controller.exit();
      expect(controller.isActive, isFalse);
    });

    test('FFI 提交点：引擎不可用时静默跳过（降级）', () async {
      final WbAnnotationController controller = WbAnnotationController(
        ffi: _demoFfi(),
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);

      await controller.enter();
      await controller.togglePenetrate();
      await controller.exit();
      expect(controller.lastError, isEmpty);
      expect(controller.isActive, isFalse);
    });

    test('退出三选项：保存到白板（过滤激光 + 快照）（§5.4）', () async {
      final List<List<WbAnnotationStroke>> saved =
          <List<WbAnnotationStroke>>[];
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
        onSaveToBoard: (List<WbAnnotationStroke> strokes) async {
          saved.add(strokes);
          return true;
        },
      );
      addTearDown(controller.dispose);

      await controller.enter();
      final WbAnnotationState state = controller.state;
      state.beginStroke(const Offset(0, 0));
      state.endStroke();
      state.beginStroke(const Offset(5, 5));
      state.endStroke();
      state.selectTool(WbAnnotationTool.laser);
      state.beginStroke(const Offset(9, 9));
      state.endStroke();
      expect(state.strokeCount, 3);

      controller.requestExit();
      expect(controller.exitDialogVisible, isTrue);
      await controller.chooseExit(WbAnnotationExitChoice.saveToBoard);

      expect(saved.single.length, 2); // 激光笔不写入白板。
      expect(controller.isActive, isFalse);
      expect(controller.exitDialogVisible, isFalse);
      expect(state.strokeCount, 0);
      expect(state.savedCount, 2);
    });

    test('退出三选项：丢弃（清空批注并退出）（§5.4）', () async {
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);

      await controller.enter();
      controller.state.beginStroke(const Offset(0, 0));
      controller.state.endStroke();
      controller.requestExit();
      await controller.chooseExit(WbAnnotationExitChoice.discard);

      expect(controller.state.strokeCount, 0);
      expect(controller.exitDialogVisible, isFalse);
      expect(controller.isActive, isFalse);
    });

    test('退出三选项：继续保留（取消退出）（§5.4）', () async {
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);

      await controller.enter();
      controller.state.beginStroke(const Offset(0, 0));
      controller.state.endStroke();
      controller.requestExit();
      await controller.chooseExit(WbAnnotationExitChoice.cancel);

      expect(controller.isActive, isTrue);
      expect(controller.exitDialogVisible, isFalse);
      expect(controller.state.strokeCount, 1);
    });

    test('保存失败：保留弹窗与批注，可重试', () async {
      bool ok = false;
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
        onSaveToBoard: (List<WbAnnotationStroke> strokes) async => ok,
      );
      addTearDown(controller.dispose);

      await controller.enter();
      controller.state.beginStroke(const Offset(0, 0));
      controller.state.endStroke();
      controller.requestExit();

      await controller.chooseExit(WbAnnotationExitChoice.saveToBoard);
      expect(controller.isActive, isTrue);
      expect(controller.exitDialogVisible, isTrue);
      expect(controller.state.strokeCount, 1);
      expect(controller.isSaving, isFalse);

      ok = true;
      await controller.chooseExit(WbAnnotationExitChoice.saveToBoard);
      expect(controller.isActive, isFalse);
      expect(controller.state.savedCount, 1);
    });

    test('保存异常：捕获并记录 lastError，批注保留', () async {
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
        onSaveToBoard: (List<WbAnnotationStroke> strokes) async {
          throw StateError('磁盘写入失败');
        },
      );
      addTearDown(controller.dispose);

      await controller.enter();
      controller.state.beginStroke(const Offset(0, 0));
      controller.state.endStroke();

      final bool result = await controller.saveToBoard();
      expect(result, isFalse);
      expect(controller.lastError, contains('保存到白板失败'));
      expect(controller.state.strokeCount, 1);
    });
  });

  group('Annotation UI（widget）', () {
    testWidgets('未激活不渲染；进入后渲染工具栏与覆盖层（右上角 24px）',
        (WidgetTester tester) async {
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);

      expect(find.byType(AnnotationToolbar), findsNothing);
      expect(find.byType(AnnotationOverlay), findsNothing);

      await controller.enter();
      await tester.pump();
      expect(find.byType(AnnotationToolbar), findsOneWidget);
      expect(find.byType(AnnotationOverlay), findsOneWidget);

      final Rect rect = tester.getRect(
        find.byKey(const ValueKey<String>('annotation-toolbar')),
      );
      expect(rect.top, closeTo(24, 0.5));
      expect(rect.right, closeTo(1280 - 24, 0.5));
    });

    testWidgets('工具选择与颜色 / 线宽调色板（§9.2）',
        (WidgetTester tester) async {
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);
      await controller.enter();
      await tester.pump();

      await tester.tap(find.byTooltip('荧光笔'));
      await tester.pump();
      expect(controller.state.tool, WbAnnotationTool.highlighter);

      await tester.tap(find.byTooltip('颜色与线宽'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('annotation-palette')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('annotation-color-4')),
      );
      await tester.pump();
      expect(controller.state.color, WbAnnotationPalette.colors[4]);

      await tester.tap(
        find.byKey(const ValueKey<String>('annotation-width-2')),
      );
      await tester.pump();
      expect(controller.state.width, WbAnnotationPalette.widths[2]);
    });

    testWidgets('穿透切换：半透明 + 徽标 + 事件放行（§4.1 / §12.2）',
        (WidgetTester tester) async {
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);
      await controller.enter();
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey<String>('annotation-mode-mouse')),
      );
      await tester.pump();
      expect(controller.isPenetrating, isTrue);
      expect(
        tester
            .widget<Opacity>(find.byKey(AnnotationToolbar.opacityKey))
            .opacity,
        closeTo(0.62, 0.001),
      );
      expect(find.text('穿透中'), findsOneWidget);

      // 穿透态：拖拽不产生笔迹（命中测试放行）。
      await tester.dragFrom(const Offset(400, 300), const Offset(80, 30));
      await tester.pump();
      expect(controller.state.strokeCount, 0);

      // 切回批注态：恢复完全交互。
      await tester.tap(
        find.byKey(const ValueKey<String>('annotation-mode-annotate')),
      );
      await tester.pump();
      expect(controller.isPenetrating, isFalse);
      expect(
        tester
            .widget<Opacity>(find.byKey(AnnotationToolbar.opacityKey))
            .opacity,
        1,
      );
      await tester.dragFrom(const Offset(400, 300), const Offset(80, 30));
      await tester.pump();
      expect(controller.state.strokeCount, 1);
    });

    testWidgets('拖拽绘制与橡皮擦除（§6.1 / §6.4）',
        (WidgetTester tester) async {
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);
      await controller.enter();
      await tester.pump();

      await tester.dragFrom(const Offset(400, 300), const Offset(120, 40));
      await tester.pump();
      expect(controller.state.strokeCount, 1);
      final WbAnnotationStroke stroke = controller.state.strokes.single;
      expect(stroke.tool, WbAnnotationTool.pen);
      expect(stroke.points.length, greaterThanOrEqualTo(2));

      controller.state.selectTool(WbAnnotationTool.eraser);
      await tester.pump();
      await tester.dragFrom(const Offset(450, 315), const Offset(20, 0));
      await tester.pump();
      expect(controller.state.strokeCount, 0);
    });

    testWidgets('激光笔轨迹自动清理（§6.1 临时高亮）',
        (WidgetTester tester) async {
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);
      await controller.enter();
      await tester.pump();

      // 注入一条已超过 1.6s 寿命的激光笔迹，帧动画应将其清理。
      final WbAnnotationState state = controller.state;
      state.selectTool(WbAnnotationTool.laser);
      state.beginStroke(
        const Offset(300, 300),
        now: DateTime.now().subtract(const Duration(seconds: 2)),
      );
      state.extendStroke(const Offset(340, 320));
      state.endStroke();
      expect(state.hasLaser, isTrue);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(state.strokeCount, 0);
      expect(state.hasLaser, isFalse);
      expect(find.byType(AnnotationOverlay), findsOneWidget);
    });

    testWidgets('Esc 打开退出弹窗；取消 / 丢弃交互（§5.3 / §5.4）',
        (WidgetTester tester) async {
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);
      await controller.enter();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.exitDialogVisible, isTrue);
      expect(find.byKey(WbAnnotationExitDialog.dialogKey), findsOneWidget);
      expect(find.text('退出透明批注模式'), findsOneWidget);

      // 继续保留：关闭弹窗、保留批注。
      await tester.tap(
        find.byKey(
          WbAnnotationExitDialog.choiceKey(WbAnnotationExitChoice.cancel),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.exitDialogVisible, isFalse);
      expect(controller.isActive, isTrue);

      // ✕ 再次打开 → 丢弃：清空并退出。
      await tester.tap(
        find.byKey(const ValueKey<String>('annotation-exit')),
      );
      await tester.pumpAndSettle();
      expect(controller.exitDialogVisible, isTrue);
      await tester.tap(
        find.byKey(
          WbAnnotationExitDialog.choiceKey(WbAnnotationExitChoice.discard),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.isActive, isFalse);
      expect(find.byKey(WbAnnotationExitDialog.dialogKey), findsNothing);
    });

    testWidgets('工具栏折叠为小胶囊并可展开（§9.1）',
        (WidgetTester tester) async {
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);
      await controller.enter();
      await tester.pump();

      await tester.tap(find.byTooltip('折叠工具栏'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('annotation-toolbar')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('annotation-toolbar-capsule')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('annotation-toolbar-capsule')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('annotation-toolbar')),
        findsOneWidget,
      );
    });

    testWidgets('按住 Alt 临时穿透，松开恢复（§4.2 / §12.3）',
        (WidgetTester tester) async {
      final WbAnnotationController controller = WbAnnotationController(
        hotkeyRegistrar: _RecordingRegistrar().call,
      );
      addTearDown(controller.dispose);
      await _pumpLayer(tester, controller);
      await controller.enter();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(controller.isTemporaryPenetrate, isTrue);
      expect(controller.isPenetratingInEffect, isTrue);

      // 临时穿透：拖拽不产生笔迹。
      await tester.dragFrom(const Offset(400, 300), const Offset(60, 0));
      await tester.pump();
      expect(controller.state.strokeCount, 0);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(controller.isTemporaryPenetrate, isFalse);

      await tester.dragFrom(const Offset(400, 300), const Offset(60, 0));
      await tester.pump();
      expect(controller.state.strokeCount, 1);
    });
  });
}
