// §8.3 端到端：页面管理 —— 侧栏新建页面、页面卡片切换。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/e2e_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 侧栏页面卡片（key 形态：`page-card-<pageId>`）。
  Finder pageCards() => find.byWidgetPredicate((Widget widget) {
        final Key? key = widget.key;
        return key is ValueKey<String> && key.value.startsWith('page-card-');
      });

  testWidgets('新建页面：卡片数 +1 且出现「页面 2」', (WidgetTester tester) async {
    await pumpEditor(tester);

    final int before = pageCards().evaluate().length;
    expect(before, greaterThanOrEqualTo(1));

    await tester.tap(find.byKey(const ValueKey<String>('pages-add')));
    await tester.pumpAndSettle();

    expect(pageCards().evaluate().length, before + 1);
    expect(find.text('页面 2'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切回第一页：画布空提示仍在且无异常', (WidgetTester tester) async {
    await pumpEditor(tester);

    await tester.tap(find.byKey(const ValueKey<String>('pages-add')));
    await tester.pumpAndSettle();

    final Finder firstPage = find.byWidgetPredicate((Widget widget) {
      final Key? key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('page-card-') &&
          key.value.endsWith('-page-1');
    });
    expect(firstPage, findsOneWidget);

    await tester.tap(firstPage);
    await tester.pumpAndSettle();

    expect(find.text('画布就绪'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
