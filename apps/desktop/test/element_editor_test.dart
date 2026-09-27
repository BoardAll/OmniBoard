/// 专业元素独立编辑页（问题 6 / 波次 C）测试：保存返回最新模型 /
/// 编辑注入初始模型 / 取消返回 null。
///
/// 路由环境用最小 GoRouter（不启动完整应用），避免触发无关 Provider。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:whiteboard_desktop/pages/element_editor_page.dart';
import 'package:whiteboard_desktop/widgets/context_editors/flowchart_editor.dart';
import 'package:whiteboard_desktop/widgets/context_editors/quick_create.dart';
import 'package:whiteboard_desktop/widgets/context_editors/table_editor.dart';

/// 最小路由：`/` 按钮 push `/edit`（extra 注入请求）并记录 pop 结果。
GoRouter _router({
  required WbElementEditorRequest request,
  required List<Object?> results,
}) {
  return GoRouter(
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (BuildContext context, GoRouterState state) => Center(
          child: TextButton(
            key: const ValueKey<String>('open-editor'),
            onPressed: () async {
              results.add(
                await context.push<Object>('/edit', extra: request),
              );
            },
            child: const Text('打开编辑器'),
          ),
        ),
      ),
      GoRoute(
        path: '/edit',
        builder: (BuildContext context, GoRouterState state) =>
            ElementEditorPage(request: state.extra! as WbElementEditorRequest),
      ),
    ],
  );
}

Future<void> _openEditor(
  WidgetTester tester, {
  required WbElementEditorRequest request,
  required List<Object?> results,
}) async {
  final GoRouter router = _router(request: request, results: results);
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey<String>('open-editor')));
  await tester.pumpAndSettle();
  expect(find.byType(ElementEditorPage), findsOneWidget);
}

void main() {
  testWidgets('新建：保存返回默认示例模型（未修改）', (WidgetTester tester) async {
    final List<Object?> results = <Object?>[];
    await _openEditor(
      tester,
      request: const WbElementEditorRequest(
        kind: WbQuickCreateKind.flowchart,
      ),
      results: results,
    );
    expect(find.byType(WbFlowchartEditor), findsOneWidget);

    await tester.tap(find.byKey(ElementEditorPage.saveKey));
    await tester.pumpAndSettle();
    expect(find.byType(ElementEditorPage), findsNothing);
    expect(results.single, isA<WbFlowchartModel>());
  });

  testWidgets('编辑：初始模型注入编辑器，保存返回表格模型', (WidgetTester tester) async {
    final List<Object?> results = <Object?>[];
    final WbTableModel initial = WbTableModel.sample();
    await _openEditor(
      tester,
      request: WbElementEditorRequest(
        kind: WbQuickCreateKind.table,
        initialModel: initial,
        elementId: 't1',
      ),
      results: results,
    );
    expect(find.byType(WbTableEditor), findsOneWidget);

    await tester.tap(find.byKey(ElementEditorPage.saveKey));
    await tester.pumpAndSettle();
    expect(results.single, isA<WbTableModel>());
    expect(find.byType(ElementEditorPage), findsNothing);
  });

  testWidgets('取消：返回 null（宿主不写回）', (WidgetTester tester) async {
    final List<Object?> results = <Object?>[];
    await _openEditor(
      tester,
      request: const WbElementEditorRequest(
        kind: WbQuickCreateKind.mindmap,
      ),
      results: results,
    );

    await tester.tap(find.byKey(ElementEditorPage.cancelKey));
    await tester.pumpAndSettle();
    expect(find.byType(ElementEditorPage), findsNothing);
    expect(results.single, isNull);
  });

  testWidgets('页内关闭（编辑器 ✕）视同取消：返回 null', (WidgetTester tester) async {
    final List<Object?> results = <Object?>[];
    await _openEditor(
      tester,
      request: const WbElementEditorRequest(
        kind: WbQuickCreateKind.render2d,
      ),
      results: results,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-editor-close')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ElementEditorPage), findsNothing);
    expect(results.single, isNull);
  });
}
