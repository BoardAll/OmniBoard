// §8.3 端到端：流程图编辑器 —— 快速创建入口打开 / 节点与自动布局交互。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:whiteboard_desktop/widgets/context_editors/flowchart_editor.dart';

import 'support/e2e_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('快速创建打开流程图编辑器并可关闭', (WidgetTester tester) async {
    await pumpEditor(tester);

    await openQuickCreate(tester, 'flowchart');
    expect(find.byType(WbFlowchartEditor), findsOneWidget);

    await dismissOverlay(tester);
    expect(find.byType(WbFlowchartEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('添加节点 + 自动布局：编辑器保持可用', (WidgetTester tester) async {
    await pumpEditor(tester);
    await openQuickCreate(tester, 'flowchart');

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-flow-add-node')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-flow-auto-layout')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(WbFlowchartEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
