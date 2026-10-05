/// Web 上下文工具栏浮层宿主（长生命周期）Widget 测试。
///
/// 覆盖三缺陷修复的交互回归：
/// - 拖动（moveElements 手势）全程隐藏浮层，松手后恢复并跟随新锚点
///   （「移动过程中不显示、结束后显示」；无全屏遮罩，指针不被拦截）；
/// - 路由级弹层（对话框）期间隐藏，退出（次级动画回落 0）后恢复——
///   全程不销毁浮层；
/// - 空选区隐藏、重选同元素恢复（同选区不再被锁定）；
/// - 多选「更多」菜单含 duplicate（复制），命令可触发；删除二次确认
///   期间浮层被弹层隐藏，确认后命令仍送达（不因 unmount 丢失）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_canvas/canvas/canvas_controller.dart';
import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/state/selection_state.dart';
import 'package:whiteboard_canvas/toolbar/toolbar_config.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_web/widgets/context_toolbar_host.dart';

/// 浮层工具栏根 key（`showWbContextToolbar` 固定值）。
const ValueKey<String> _popupKey =
    ValueKey<String>('wb-context-toolbar-popup');

/// 「更多」按钮 key（默认前缀 `wb-context-`）。
const ValueKey<String> _moreKey = ValueKey<String>('wb-context-more');

/// 删除确认框确定按钮 key。
const ValueKey<String> _deleteOkKey =
    ValueKey<String>('wb-delete-confirm-ok');

/// 构造测试便签元素（世界坐标 x/y 起）。
WbCanvasElement _note(String id, double x, double y) => WbCanvasElement(
      id: id,
      type: 'note',
      x: x,
      y: y,
      width: 100,
      height: 60,
    );

/// 挂载宿主（画布视口 600×400，居中；含主题扩展）。
Future<void> _pumpHost(
  WidgetTester tester, {
  required WbCanvasController controller,
  ValueChanged<WbToolbarCommand>? onCommand,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: kCleanProfessionalTheme.toFlutterThemeData(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 600,
          height: 400,
          child: WbWebContextToolbarHost(
            controller: controller,
            onCommand: onCommand,
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

/// 帧末同步（postFrame 驱动 `_sync`）+ overlay 重建两帧。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('拖动中隐藏、松手后恢复并跟随锚点（移动过程中不显示）',
      (WidgetTester tester) async {
    final WbCanvasController controller =
        WbCanvasController(selection: WbSelectionState());
    controller.document.upsert('', _note('e1', 10, 20));
    await _pumpHost(tester, controller: controller);

    controller.selection!.select(<String>['e1']);
    await _settle(tester);
    final Finder popup = find.byKey(_popupKey);
    expect(popup, findsOneWidget);
    final Rect before = tester.getRect(popup);

    // 已选中元素上按下（select 工具）→ moveElements 手势：浮层隐藏。
    controller.handlePointerDown(1, const Offset(50, 50), shift: false);
    await _settle(tester);
    expect(find.byKey(_popupKey), findsNothing);

    // 拖动中持续隐藏（Offstage 保活，不销毁）。
    controller.handlePointerMove(1, const Offset(70, 70));
    await _settle(tester);
    expect(find.byKey(_popupKey), findsNothing);

    // 松手：手势落回 idle → 恢复显示并跟随新锚点（元素位移 +20,+20）。
    controller.handlePointerUp(1, const Offset(70, 70));
    await _settle(tester);
    expect(find.byKey(_popupKey), findsOneWidget);
    final Rect after = tester.getRect(find.byKey(_popupKey));
    expect(after.top - before.top, moreOrLessEquals(20, epsilon: 0.5));
  });

  testWidgets('路由弹层（对话框）期间隐藏、退出后恢复（不销毁）',
      (WidgetTester tester) async {
    final WbCanvasController controller =
        WbCanvasController(selection: WbSelectionState());
    controller.document.upsert('', _note('e1', 10, 20));
    await _pumpHost(tester, controller: controller);

    controller.selection!.select(<String>['e1']);
    await _settle(tester);
    expect(find.byKey(_popupKey), findsOneWidget);

    // 推入路由级弹层：期间浮层隐藏。
    final BuildContext hostContext =
        tester.element(find.byType(WbWebContextToolbarHost));
    unawaited(showDialog<void>(
      context: hostContext,
      builder: (BuildContext context) =>
          const AlertDialog(title: Text('弹层确认')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('弹层确认'), findsOneWidget);
    expect(find.byKey(_popupKey), findsNothing);

    // 弹层退出：次级动画回落 0 → 恢复显示（浮层未销毁，直接复显）。
    Navigator.of(hostContext).pop();
    await tester.pumpAndSettle();
    expect(find.text('弹层确认'), findsNothing);
    expect(find.byKey(_popupKey), findsOneWidget);
  });

  testWidgets('空选区隐藏、重选同元素恢复（无同选区锁定）',
      (WidgetTester tester) async {
    final WbCanvasController controller =
        WbCanvasController(selection: WbSelectionState());
    controller.document.upsert('', _note('e1', 10, 20));
    await _pumpHost(tester, controller: controller);

    controller.selection!.select(<String>['e1']);
    await _settle(tester);
    expect(find.byKey(_popupKey), findsOneWidget);

    // 点击空白语义：选区清空 → 宿主隐藏。
    controller.selection!.clear();
    await _settle(tester);
    expect(find.byKey(_popupKey), findsNothing);

    // 重选同一元素 → 立即恢复（修复前 _dismissedKey 会锁死不再打开）。
    controller.selection!.select(<String>['e1']);
    await _settle(tester);
    expect(find.byKey(_popupKey), findsOneWidget);
  });

  testWidgets('多选「更多」含复制；删除确认期间隐藏但命令不丢',
      (WidgetTester tester) async {
    final WbCanvasController controller =
        WbCanvasController(selection: WbSelectionState());
    controller.document.upsert('', _note('e1', 10, 20));
    controller.document.upsert('', _note('e2', 200, 20));
    final List<WbToolbarCommand> commands = <WbToolbarCommand>[];
    await _pumpHost(tester, controller: controller, onCommand: commands.add);

    controller.selection!.select(<String>['e1', 'e2']);
    await _settle(tester);
    expect(find.byKey(_popupKey), findsOneWidget);
    // 多选类型标签（单选功能含多选：条目数按 multiSelect spec 渲染）。
    expect(find.text('多选 ×2'), findsOneWidget);

    // 「更多」→ 复制（duplicate）条目存在并可触发。
    await tester.tap(find.byKey(_moreKey));
    await tester.pumpAndSettle();
    final Finder duplicate =
        find.byKey(const ValueKey<String>('wb-toolbar-more-item-duplicate'));
    expect(duplicate, findsOneWidget);
    await tester.tap(duplicate);
    await tester.pumpAndSettle();
    expect(
      commands.map((WbToolbarCommand c) => c.toolId),
      contains('element.duplicate'),
    );

    // 删除（二次确认）：确认框推入期间浮层被弹层隐藏。
    await tester.tap(find.byKey(_moreKey));
    await tester.pumpAndSettle();
    final Finder delete =
        find.byKey(const ValueKey<String>('wb-toolbar-more-item-delete'));
    expect(delete, findsOneWidget);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wb-delete-confirm')),
      findsOneWidget,
    );
    expect(find.byKey(_popupKey), findsNothing);

    // 确认框期间画布仍有活动（通知）——浮层保持隐藏但不销毁。
    controller.setSpacePressed(true);
    controller.setSpacePressed(false);
    await tester.pumpAndSettle();
    expect(find.byKey(_popupKey), findsNothing);

    // 确认删除：命令照发（不因浮层隐藏 / 卸载而丢失）。
    await tester.tap(find.byKey(_deleteOkKey));
    await tester.pumpAndSettle();
    expect(
      commands.map((WbToolbarCommand c) => c.toolId),
      contains('element.delete'),
    );
    // 弹层退出后浮层恢复显示。
    expect(find.byKey(_popupKey), findsOneWidget);
  });
}
