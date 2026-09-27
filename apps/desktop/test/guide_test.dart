/// 用户手册与引导 UI 测试（Wave 4.5）：
/// 引导步骤推进 / 跳过 / 完成 / 不再提示、快捷键卡片分组渲染、
/// 帮助中心分节切换与搜索、FAQ 展开、无 Provider 独立渲染。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/services/shortcut_service.dart';
import 'package:whiteboard_desktop/widgets/guide/guide_content.dart';
import 'package:whiteboard_desktop/widgets/guide/help_center.dart';
import 'package:whiteboard_desktop/widgets/guide/onboarding_overlay.dart';
import 'package:whiteboard_desktop/widgets/guide/shortcut_card.dart';

/// 放大的测试视口（面板与浮层需要足够空间）。
void _useLargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 裸 MaterialApp 宿主（无 Provider）。
Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  group('引导内容数据（单元）', () {
    test('引导步骤对齐文档 §3.2：7 步、文案非空、锚点比例合法', () {
      const List<WbGuideStep> steps = WbGuideContent.onboardingSteps;
      expect(steps.length, 7);
      expect(steps.first.id, 'radial');
      expect(steps.last.id, 'done');
      for (final WbGuideStep step in steps) {
        expect(step.id, isNotEmpty);
        expect(step.title, isNotEmpty);
        expect(step.message, isNotEmpty);
        expect(step.icon, isNotEmpty);
        expect(step.anchor.left, inInclusiveRange(0.0, 1.0));
        expect(step.anchor.top, inInclusiveRange(0.0, 1.0));
        expect(step.anchor.left + step.anchor.width, lessThanOrEqualTo(1.0));
        expect(step.anchor.top + step.anchor.height, lessThanOrEqualTo(1.0));
      }
      // 锚点解析：bottomRight 按屏幕比例换算。
      final Rect rect = WbGuideAnchor.bottomRight.resolve(1000, 800);
      expect(rect.width, closeTo(220, 0.001));
      expect(rect.height, closeTo(224, 0.001));
    });

    test('快捷键分组：4 组 / 覆盖总表 / 动态条目与 shortcut_service 一致', () {
      const List<WbGuideShortcutGroup> groups = WbGuideContent.shortcutGroups;
      expect(groups.length, 4);
      expect(groups.map((WbGuideShortcutGroup g) => g.id).toSet().length, 4);

      final List<WbGuideShortcut> all = groups
          .expand((WbGuideShortcutGroup g) => g.entries)
          .toList(growable: false);
      expect(all.length, 37);
      expect(
        all.map((WbGuideShortcut s) => s.id).toSet().length,
        all.length,
        reason: '条目 id 应唯一',
      );
      for (final WbGuideShortcut entry in all) {
        expect(entry.label, isNotEmpty);
        expect(entry.resolvedKeys, isNotEmpty);
      }

      // 标注 shortcutId 的条目与注册表逐一对齐（平台动态解析）。
      final List<WbGuideShortcut> linked = all
          .where((WbGuideShortcut s) => s.shortcutId.isNotEmpty)
          .toList(growable: false);
      expect(linked.length, 12);
      for (final WbGuideShortcut entry in linked) {
        expect(
          entry.resolvedKeys,
          WbShortcutService.describeById(entry.shortcutId),
          reason: '${entry.id} 键位应与 WbShortcutService 一致',
        );
      }
      // 未知 shortcutId 回退到静态键位文本。
      const WbGuideShortcut fallback = WbGuideShortcut(
        id: 'x',
        label: 'X',
        keys: 'K',
        shortcutId: 'missing.id',
      );
      expect(fallback.resolvedKeys, 'K');
    });

    test('搜索：跨分节命中、空白与未知词返回空', () {
      final List<WbGuideSearchHit> hits = WbGuideContent.search('便签');
      expect(hits, isNotEmpty);
      expect(
        hits.any((WbGuideSearchHit h) =>
            h.section == WbGuideSection.quickStart),
        isTrue,
      );
      expect(
        hits.any((WbGuideSearchHit h) => h.section == WbGuideSection.manual),
        isTrue,
      );
      for (final WbGuideSearchHit hit in hits) {
        expect(hit.title, isNotEmpty);
        expect(hit.detail, isNotEmpty);
      }

      expect(
        WbGuideContent.search('AI')
            .any((WbGuideSearchHit h) => h.section == WbGuideSection.faq),
        isTrue,
      );
      expect(WbGuideContent.search('   '), isEmpty);
      expect(WbGuideContent.search('zzz-unknown-word'), isEmpty);
    });
  });

  group('WbOnboardingOverlay / showOnboardingOverlay', () {
    testWidgets('首帧渲染第 1 步：标题、进度 1/7、高亮与卡片', (WidgetTester tester) async {
      _useLargeViewport(tester);
      await tester.pumpWidget(_host(
        WbOnboardingOverlay(onFinish: (WbOnboardingResult result) {}),
      ));
      await tester.pumpAndSettle();

      expect(find.text('认识圆盘'), findsOneWidget);
      expect(find.text('1/7'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('wb-guide-card')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('wb-guide-highlight')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('wb-guide-mask')), findsOneWidget);
      // 第一步不显示「上一步」。
      expect(find.byKey(const ValueKey<String>('wb-guide-prev')), findsNothing);
    });

    testWidgets('下一步推进、上一步回退并回调 onStepChanged', (WidgetTester tester) async {
      _useLargeViewport(tester);
      final List<int> changed = <int>[];
      await tester.pumpWidget(_host(
        WbOnboardingOverlay(
          onFinish: (WbOnboardingResult result) {},
          onStepChanged: (int index) => changed.add(index),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-next')));
      await tester.pumpAndSettle();
      expect(find.text('创建便签'), findsOneWidget);
      expect(find.text('2/7'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-prev')));
      await tester.pumpAndSettle();
      expect(find.text('认识圆盘'), findsOneWidget);
      expect(find.text('1/7'), findsOneWidget);

      expect(changed, <int>[1, 0]);
    });

    testWidgets('走完 7 步点击完成：completed + lastStepIndex=6', (WidgetTester tester) async {
      _useLargeViewport(tester);
      WbOnboardingResult? received;
      await tester.pumpWidget(_host(
        WbOnboardingOverlay(
          onFinish: (WbOnboardingResult result) => received = result,
        ),
      ));
      await tester.pumpAndSettle();

      for (int i = 0; i < 6; i++) {
        await tester.tap(find.byKey(const ValueKey<String>('wb-guide-next')));
        await tester.pumpAndSettle();
      }
      expect(find.text('引导完成'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('wb-guide-done-extra')),
          findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-next')));
      await tester.pumpAndSettle();

      expect(received, isNotNull);
      expect(received!.outcome, WbOnboardingOutcome.completed);
      expect(received!.completed, isTrue);
      expect(received!.lastStepIndex, 6);
      expect(received!.dontShowAgain, isFalse);
    });

    testWidgets('跳过按钮：skipped 且只回调一次', (WidgetTester tester) async {
      _useLargeViewport(tester);
      final List<WbOnboardingResult> results = <WbOnboardingResult>[];
      await tester.pumpWidget(_host(
        WbOnboardingOverlay(
          onFinish: (WbOnboardingResult result) => results.add(result),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-skip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-skip')));
      await tester.pumpAndSettle();

      expect(results.length, 1);
      expect(results.single.outcome, WbOnboardingOutcome.skipped);
      expect(results.single.lastStepIndex, 0);
    });

    testWidgets('✕ 关闭按钮：skipped 且重复触发不重复回调', (WidgetTester tester) async {
      _useLargeViewport(tester);
      final List<WbOnboardingResult> results = <WbOnboardingResult>[];
      await tester.pumpWidget(_host(
        WbOnboardingOverlay(
          onFinish: (WbOnboardingResult result) => results.add(result),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-close')));
      await tester.pumpAndSettle();
      // 再点「跳过」，应被防重入拦截。
      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-skip')));
      await tester.pumpAndSettle();

      expect(results.length, 1);
      expect(results.single.outcome, WbOnboardingOutcome.skipped);
    });

    testWidgets('勾选「不再提示」后完成：dontShowAgain=true', (WidgetTester tester) async {
      _useLargeViewport(tester);
      WbOnboardingResult? received;
      await tester.pumpWidget(_host(
        WbOnboardingOverlay(
          onFinish: (WbOnboardingResult result) => received = result,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-dont-show')));
      await tester.pumpAndSettle();

      for (int i = 0; i < 7; i++) {
        await tester.tap(find.byKey(const ValueKey<String>('wb-guide-next')));
        await tester.pumpAndSettle();
      }

      expect(received, isNotNull);
      expect(received!.outcome, WbOnboardingOutcome.completed);
      expect(received!.dontShowAgain, isTrue);
    });

    testWidgets('showOnboardingOverlay：模态打开、跳过返回 skipped', (WidgetTester tester) async {
      _useLargeViewport(tester);
      WbOnboardingResult? received;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const ValueKey<String>('wb-guide-test-open-onboarding'),
                  onPressed: () {
                    unawaited(showOnboardingOverlay(context)
                        .then((WbOnboardingResult result) {
                      received = result;
                    }));
                  },
                  child: const Text('打开引导'),
                ),
              ),
            );
          },
        ),
      ));

      await tester.tap(
        find.byKey(const ValueKey<String>('wb-guide-test-open-onboarding')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('wb-guide-card')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-skip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('wb-guide-card')), findsNothing);
      expect(received, isNotNull);
      expect(received!.outcome, WbOnboardingOutcome.skipped);
    });
  });

  group('WbShortcutCard / WbShortcutKeys', () {
    testWidgets('快捷键卡片：分组标题 / 条目 / 键帽渲染', (WidgetTester tester) async {
      _useLargeViewport(tester);
      await tester.pumpWidget(_host(
        const SingleChildScrollView(child: WbShortcutCard()),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('wb-guide-shortcut-card')),
          findsOneWidget);
      for (final String groupId in <String>['general', 'tools', 'edit', 'view']) {
        expect(
          find.byKey(ValueKey<String>('wb-guide-shortcut-group-$groupId')),
          findsOneWidget,
          reason: '缺少分组：$groupId',
        );
      }
      expect(find.text('通用'), findsOneWidget);
      expect(find.text('工具切换'), findsOneWidget);

      // 指定条目：动作名 + 键帽（动态键位按 `+` 拆分）。
      final Finder undoRow =
          find.byKey(const ValueKey<String>('wb-guide-shortcut-edit.undo'));
      expect(undoRow, findsOneWidget);
      expect(
        find.descendant(of: undoRow, matching: find.text('撤销')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: undoRow, matching: find.textContaining('Z')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('wb-guide-shortcut-tool.sticky')),
        findsOneWidget,
      );
    });

    testWidgets('快捷键卡片：紧凑模式与自定义分组', (WidgetTester tester) async {
      _useLargeViewport(tester);
      await tester.pumpWidget(_host(
        const SingleChildScrollView(
          child: WbShortcutCard(
            compact: true,
            title: '我的快捷键',
            groups: <WbGuideShortcutGroup>[
              WbGuideShortcutGroup(
                id: 'custom',
                name: '自定义',
                icon: 'pen',
                entries: <WbGuideShortcut>[
                  WbGuideShortcut(id: 'custom.act', label: '自定义动作', keys: 'Ctrl+Alt+K'),
                ],
              ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('我的快捷键'), findsOneWidget);
      expect(find.text('自定义动作'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('wb-guide-shortcut-custom.act')),
        findsOneWidget,
      );
    });

    testWidgets('WbShortcutKeys：加号拆分与整段展示', (WidgetTester tester) async {
      _useLargeViewport(tester);
      await tester.pumpWidget(_host(
        const Column(
          children: <Widget>[
            WbShortcutKeys(keys: 'Ctrl+Shift+Z'),
            WbShortcutKeys(keys: '长按画布 / 点击右下角'),
          ],
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Ctrl'), findsOneWidget);
      expect(find.text('Shift'), findsOneWidget);
      expect(find.text('Z'), findsOneWidget);
      expect(find.text('长按画布 / 点击右下角'), findsOneWidget);
    });
  });

  group('WbHelpCenter / showHelpCenter', () {
    testWidgets('默认快速上手分节并支持分节切换', (WidgetTester tester) async {
      _useLargeViewport(tester);
      await tester.pumpWidget(_host(
        const Center(
          child: SizedBox(width: 900, height: 620, child: WbHelpCenter()),
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('wb-guide-section-quick-start')),
        findsOneWidget,
      );
      expect(find.text('5 分钟上手白板'), findsOneWidget);
      expect(find.text('打开圆盘'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-nav-manual')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-section-manual')),
        findsOneWidget,
      );
      expect(find.text('用户手册'), findsWidgets);

      await tester.tap(
        find.byKey(const ValueKey<String>('wb-guide-nav-advanced')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-section-advanced')),
        findsOneWidget,
      );
      expect(find.text('效率技巧'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-nav-faq')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-section-faq')),
        findsOneWidget,
      );
      expect(find.text('常见问题'), findsOneWidget);
    });

    testWidgets('用户手册章节展开显示条目', (WidgetTester tester) async {
      _useLargeViewport(tester);
      await tester.pumpWidget(_host(
        const Center(
          child: SizedBox(width: 900, height: 620, child: WbHelpCenter()),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-nav-manual')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('wb-guide-manual-0')),
          findsOneWidget);
      await tester.tap(find.text('01 入门'));
      await tester.pumpAndSettle();
      expect(find.text('03 圆盘工具栏'), findsOneWidget);
      expect(find.text('06 快捷键'), findsOneWidget);

      await tester.tap(find.text('01 入门'));
      await tester.pumpAndSettle();
      expect(find.text('03 圆盘工具栏'), findsNothing);
    });

    testWidgets('FAQ 展开 / 收起', (WidgetTester tester) async {
      _useLargeViewport(tester);
      await tester.pumpWidget(_host(
        const Center(
          child: SizedBox(width: 900, height: 620, child: WbHelpCenter()),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-nav-faq')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-faq-create-board')),
        findsOneWidget,
      );

      await tester.tap(find.text('如何创建白板？'));
      await tester.pumpAndSettle();
      expect(find.text('点击白板列表的「新建」按钮。'), findsOneWidget);

      await tester.tap(find.text('如何创建白板？'));
      await tester.pumpAndSettle();
      expect(find.text('点击白板列表的「新建」按钮。'), findsNothing);
    });

    testWidgets('搜索：命中列表 / 点击跳转分节 / 清空恢复 / 无结果提示', (WidgetTester tester) async {
      _useLargeViewport(tester);
      await tester.pumpWidget(_host(
        const Center(
          child: SizedBox(width: 900, height: 620, child: WbHelpCenter()),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('wb-guide-help-search')),
        '便签',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-search-results')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('wb-guide-search-hit-0')),
        findsOneWidget,
      );
      expect(find.text('创建便签'), findsWidgets);

      await tester.tap(
        find.byKey(const ValueKey<String>('wb-guide-search-hit-0')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-search-results')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('wb-guide-section-quick-start')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey<String>('wb-guide-help-search')),
        'zzz-unknown',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-search-empty')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey<String>('wb-guide-help-search')),
        '',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-section-quick-start')),
        findsOneWidget,
      );
    });

    testWidgets('关闭按钮触发 onClose 回调', (WidgetTester tester) async {
      _useLargeViewport(tester);
      bool closed = false;
      await tester.pumpWidget(_host(
        Center(
          child: SizedBox(
            width: 900,
            height: 620,
            child: WbHelpCenter(onClose: () => closed = true),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-help-close')));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
    });

    testWidgets('showHelpCenter：模态打开、关闭', (WidgetTester tester) async {
      _useLargeViewport(tester);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const ValueKey<String>('wb-guide-test-open-help'),
                  onPressed: () {
                    unawaited(showHelpCenter(context));
                  },
                  child: const Text('打开帮助'),
                ),
              ),
            );
          },
        ),
      ));

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-test-open-help')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-help-close')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('wb-guide-section-quick-start')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-help-close')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-help-close')),
        findsNothing,
      );
    });
  });

  group('无 Provider 独立渲染', () {
    testWidgets('帮助中心 / 快捷键卡片 / 引导浮层裸环境渲染与交互',
        (WidgetTester tester) async {
      _useLargeViewport(tester);

      // 帮助中心：渲染 + 分节切换。
      await tester.pumpWidget(_host(
        const Center(
          child: SizedBox(width: 900, height: 620, child: WbHelpCenter()),
        ),
      ));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-section-quick-start')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-nav-faq')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('wb-guide-section-faq')),
        findsOneWidget,
      );

      // 快捷键卡片。
      await tester.pumpWidget(_host(
        const SingleChildScrollView(child: WbShortcutCard()),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('wb-guide-shortcut-card')),
          findsOneWidget);

      // 引导浮层：渲染 + 下一步交互。
      await tester.pumpWidget(_host(
        WbOnboardingOverlay(onFinish: (WbOnboardingResult result) {}),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('wb-guide-card')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('wb-guide-next')));
      await tester.pumpAndSettle();
      expect(find.text('2/7'), findsOneWidget);
    });
  });
}
