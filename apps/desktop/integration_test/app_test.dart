// §8.3 端到端：应用启动 / 首页 / 设置与帮助中心导航冒烟。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:whiteboard_desktop/widgets/guide/help_center.dart';

import 'support/e2e_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('启动进入「我的白板」首页（FFI 缺失降级演示模式）',
      (WidgetTester tester) async {
    await pumpApp(tester);

    expect(find.text('我的白板'), findsOneWidget);
    expect(find.text('还没有白板'), findsOneWidget);
    expect(find.text('新建白板'), findsOneWidget);
    expect(find.text('演示模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页 → 设置 → 返回：主题分区可见', (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('settings-section-card-主题')),
      findsOneWidget,
    );

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('我的白板'), findsOneWidget);
  });

  testWidgets('编辑页帮助中心：打开并关闭', (WidgetTester tester) async {
    await pumpEditor(tester);

    await tester.tap(find.byTooltip('帮助中心'));
    await tester.pumpAndSettle();
    expect(find.byType(WbHelpCenter), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(WbHelpCenter), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
