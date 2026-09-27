/// tests/e2e 端到端（《Flutter + C++ 工程结构设计》§12.3）：AI 流程。
///
/// 完整流程：进入编辑页 → AI 面板默认展开 → 发送消息（未配置提供商降级
/// 提示）→ 面板收展。
///
/// 运行（VM，无需设备）：
/// `flutter test ai_flow_test.dart` 或包根 `flutter test`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/ai_panel.dart';

import 'support/e2e_support.dart';

void main() {
  testWidgets('发送消息：未配置提供商时给出去「设置」的降级提示',
      (WidgetTester tester) async {
    await pumpEditor(tester);

    // 编辑页默认展开 AI 面板（宽 320）。
    expect(find.byType(AiPanel), findsOneWidget);
    expect(find.text('AI 助手'), findsOneWidget);
    expect(find.text('尚未配置 AI 提供商'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('ai.panel.input')),
      '帮我总结当前页面',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai.panel.send')));
    await tester.pumpAndSettle();

    expect(
      find.text('AI 提供商未配置：请在「设置」中选择模型服务后再试。'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 面板收展：收起后隐藏、展开后回归', (WidgetTester tester) async {
    await pumpEditor(tester);
    expect(find.byType(AiPanel), findsOneWidget);

    await tester.tap(find.byTooltip('收起 AI 面板'));
    await tester.pumpAndSettle();
    expect(find.byType(AiPanel), findsNothing);

    await tester.tap(find.byTooltip('展开 AI 面板'));
    await tester.pumpAndSettle();
    expect(find.byType(AiPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
