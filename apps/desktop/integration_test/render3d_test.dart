// §8.3 端到端：3D 对象编辑器 —— 预览、对象类型 / 材质切换、重置。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:whiteboard_desktop/widgets/context_editors/render3d_editor.dart';

import 'support/e2e_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('3D 编辑器：类型 / 材质切换与重置', (WidgetTester tester) async {
    await pumpEditor(tester);

    await openQuickCreate(tester, 'render3d');
    expect(find.byType(WbRender3dEditor), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('wb-ctx-3d-preview')),
        findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-3d-type-sphere')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-3d-material-glass')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('wb-ctx-3d-reset')));
    await tester.pumpAndSettle();

    expect(find.byType(WbRender3dEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('3D 编辑器：关闭后对话框完全回收', (WidgetTester tester) async {
    await pumpEditor(tester);
    await openQuickCreate(tester, 'render3d');

    await dismissOverlay(tester);
    expect(find.byType(WbRender3dEditor), findsNothing);
    expect(find.text('画布就绪'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
