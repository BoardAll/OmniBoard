// §8.3 端到端：在编辑页通过画布工具创建元素（便签）并撤销。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:whiteboard_desktop/services/theme_service.dart';
import 'package:whiteboard_desktop/state/theme_state.dart';
import 'package:whiteboard_desktop/widgets/canvas_view.dart';

import 'support/e2e_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 画布内联文本编辑器（排除 AI 面板等其他输入框）。
  Finder canvasTextField() => find.descendant(
        of: find.byType(CanvasView),
        matching: find.byType(TextField),
      );

  /// 进入编辑页并显式切换到顶部工具面板风格。
  ///
  /// 应用默认工具栏为径向圆盘（radial），`wb-canvas-tool-*` 顶部面板
  /// 仅在 `toolbarStyle == top` 时渲染（B3 二选一）；本用例聚焦
  /// 「创建元素」数据流，风格假设与 board_wiring_test 同款手法显式声明。
  Future<void> pumpEditorWithTopToolbar(WidgetTester tester) async {
    final WbThemeState theme = await pumpEditor(tester);
    theme.applyAppearance(
      theme.appearance.copyWith(
        toolbarStyle: WbAppearancePrefs.toolbarStyleTop,
      ),
    );
    await tester.pumpAndSettle();
  }

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
    await pumpEditorWithTopToolbar(tester);
    expect(find.text('画布就绪'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-canvas-tool-sticky')),
    );
    await tester.pump();
    await tester.tapAt(kCanvasCenter);
    await tester.pump();
    await tester.pump();

    expect(canvasTextField(), findsOneWidget);

    await tester.enterText(canvasTextField(), '集成测试便签');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // 元素已落在画布：空提示消失、编辑框关闭。
    expect(find.text('画布就绪'), findsNothing);
    expect(canvasTextField(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('创建后撤销：连续两步撤销回到空页面', (WidgetTester tester) async {
    await pumpEditorWithTopToolbar(tester);

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
