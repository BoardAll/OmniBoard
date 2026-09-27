// §8.3 端到端：函数图像编辑器 —— 表达式校验、曲线增删。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:whiteboard_desktop/widgets/context_editors/function_editor.dart';

import 'support/e2e_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('表达式校验：非法输入提示 → 修正后提示消失', (WidgetTester tester) async {
    await pumpEditor(tester);
    await openQuickCreate(tester, 'function');

    expect(find.byType(WbFunctionEditor), findsOneWidget);

    final Finder expr = find.byKey(const ValueKey<String>('wb-ctx-func-expr'));
    final TextField field = tester.widget<TextField>(expr);
    expect(field.controller!.text, 'sin(x)');

    await tester.enterText(expr, 'sin(');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('wb-ctx-func-error')),
        findsOneWidget);

    await tester.enterText(expr, 'x^2');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('wb-ctx-func-error')),
        findsNothing);

    await dismissOverlay(tester);
    expect(find.byType(WbFunctionEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('曲线增删：添加后移除，编辑器保持可用', (WidgetTester tester) async {
    await pumpEditor(tester);
    await openQuickCreate(tester, 'function');

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-func-add-curve')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-func-remove-curve')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(WbFunctionEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
