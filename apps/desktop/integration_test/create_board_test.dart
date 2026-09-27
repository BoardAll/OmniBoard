// §8.3 端到端：创建白板（首页 → 编辑页 → 返回列表）。
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('新建白板：进入编辑页并可返回列表', (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('新建白板'));
    await tester.pumpAndSettle();

    // 编辑页就绪：画布空提示 + 演示白板标题 + 演示 chip + 返回入口。
    expect(find.text('画布就绪'), findsOneWidget);
    expect(find.text('演示白板'), findsWidgets);
    expect(find.text('演示'), findsOneWidget);
    expect(find.byTooltip('返回列表'), findsOneWidget);

    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();

    // 回到列表：出现最近白板卡片。
    expect(find.text('我的白板'), findsOneWidget);
    expect(find.text('未命名白板 1'), findsOneWidget);
    expect(find.text('还没有白板'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('连续创建两块白板：列表累积最近白板', (WidgetTester tester) async {
    await pumpApp(tester);

    for (int i = 1; i <= 2; i++) {
      await tester.tap(find.text('新建白板'));
      await tester.pumpAndSettle();
      expect(find.text('画布就绪'), findsOneWidget);
      await tester.tap(find.byTooltip('返回列表'));
      await tester.pumpAndSettle();
    }

    expect(find.text('未命名白板 1'), findsOneWidget);
    expect(find.text('未命名白板 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
