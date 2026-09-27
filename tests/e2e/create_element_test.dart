/// tests/e2e 端到端（《Flutter + C++ 工程结构设计》§12.3）：创建元素。
///
/// 完整流程：进入编辑页 → 画布工具（便签）→ 点击创建 → 内联输入文本 →
/// Esc 提交 → 撤销回到空页面。
///
/// 运行（VM，无需设备）：
/// `flutter test create_element_test.dart` 或包根 `flutter test`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/canvas_view.dart';

import 'support/e2e_support.dart';

void main() {
  // 画布内联文本编辑器（排除 AI 面板等其他输入框）。
  Finder canvasTextField() => find.descendant(
        of: find.byType(CanvasView),
        matching: find.byType(TextField),
      );

  /// 工具 → 画布 → 输入文本 → Esc 提交，返回后元素应落在画布。
  Future<void> createStickyWithText(WidgetTester tester, String text) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('wb-canvas-tool-sticky')),
    );
    await tester.pump();
    await tester.tapAt(kCanvasCenter);
    await tester.pump();
    await tester.pump();
    await tester.enterText(canvasTextField(), text);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  testWidgets('工具创建便签：进入编辑态 → 输入文本 → Esc 提交',
      (WidgetTester tester) async {
    await pumpEditor(tester);
    expect(find.text('画布就绪'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-canvas-tool-sticky')),
    );
    await tester.pump();
    await tester.tapAt(kCanvasCenter);
    await tester.pump();
    await tester.pump();

    expect(canvasTextField(), findsOneWidget);

    await tester.enterText(canvasTextField(), '端到端便签');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 元素已落在画布：空提示消失、编辑框关闭。
    expect(find.text('画布就绪'), findsNothing);
    expect(canvasTextField(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('创建后撤销：连续两步撤销回到空页面', (WidgetTester tester) async {
    await pumpEditor(tester);

    // 注意：空文本按 Esc 会取消创建（endTextEditing 删除空元素），
    // 因此必须先输入内容再提交。
    await createStickyWithText(tester, '待撤销便签');
    expect(find.text('画布就绪'), findsNothing);

    // 撤销粒度（实测）：①清除首段文本 ②移除元素（创建时快照为原始空页）。
    await tester.tap(find.byKey(const Key('wb-canvas-undo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wb-canvas-undo')));
    await tester.pumpAndSettle();

    expect(find.text('画布就绪'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
