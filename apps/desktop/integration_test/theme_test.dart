// §8.3 端到端：主题切换 —— 编辑页 → 设置页 → 主题卡片选中态与背景预设。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 编辑页「设置」入口（AppBar 内）。
  ///
  /// 注意：侧栏 rail 的 `rail-settings` 以透明 + IgnorePointer 常驻组件树，
  /// 直接用 `find.byTooltip('设置')` 会命中 2 个，需限定在 AppBar 内。
  Finder editorSettingsButton() => find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('设置'),
      );

  /// 设置页为长列表（懒构建）：加高视口保证目标分区被构建（与
  /// settings_deep_test 的策略一致）。
  Future<void> pumpSettingsPage(WidgetTester tester) async {
    await pumpEditor(tester);
    tester.view.physicalSize = const Size(1600, 4600);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpAndSettle();

    await tester.tap(editorSettingsButton());
    await tester.pumpAndSettle();
  }

  testWidgets('切换深色主题：选中态迁移', (WidgetTester tester) async {
    await pumpSettingsPage(tester);

    expect(
      find.byKey(const ValueKey<String>('settings-section-card-主题')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('theme-card-check-clean-professional')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('theme-card-dark-night')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('theme-card-check-dark-night')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('theme-card-check-clean-professional')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换主题后背景预设分区仍可见', (WidgetTester tester) async {
    await pumpSettingsPage(tester);

    await tester.tap(find.byKey(const ValueKey<String>('theme-card-kids')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('theme-card-check-kids')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('background-preset-whiteboard')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
