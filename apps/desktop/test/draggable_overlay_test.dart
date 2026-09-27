/// `WbDraggableOverlay` 深度测试：tap 穿透 / 拖动移动 / clamp / 回调。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/canvas/draggable_overlay.dart';

/// 在 1600x1000 窗口中挂载面板（`bottomRight` + 可注入初始偏移）。
Future<void> _pumpOverlay(
  WidgetTester tester, {
  required Widget child,
  Alignment alignment = Alignment.bottomRight,
  Offset initialOffset = Offset.zero,
  ValueChanged<Offset>? onMoved,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            const Positioned.fill(child: ColoredBox(color: Colors.white)),
            WbDraggableOverlay(
              alignment: alignment,
              padding: const EdgeInsets.all(16),
              initialOffset: initialOffset,
              onMoved: onMoved,
              child: child,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 面板内容：灰色块 + 探针按钮（可点击计数）。
Widget _panel(int Function() tapCounter) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Container(width: 168, height: 108, color: Colors.grey),
      const SizedBox(height: 8),
      TextButton(
        key: const Key('probe-btn'),
        onPressed: () => tapCounter(),
        child: const Text('probe'),
      ),
    ],
  );
}

void main() {
  testWidgets('初始偏移生效且内部按钮 tap 不受影响', (WidgetTester tester) async {
    int taps = 0;
    await _pumpOverlay(
      tester,
      initialOffset: const Offset(0, -356),
      child: _panel(() => taps++),
    );

    // bottomRight 基位（1000-16-164=820）再上移 356 → 面板 top=464，
    // 按钮 top = 464 + 108 + 8 = 580，中心 dy = 580 + 48/2 = 604。
    final Rect rect = tester.getRect(find.byKey(const Key('probe-btn')));
    expect(rect.top, closeTo(580, 1));
    expect(rect.center.dy, closeTo(1000 - 16 - 48 / 2 - 356, 1));

    await tester.tap(find.byKey(const Key('probe-btn')));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('拖动面板：从按钮上起拖由 pan 接管、tap 被取消', (WidgetTester tester) async {
    int taps = 0;
    final List<Offset> moved = <Offset>[];
    await _pumpOverlay(
      tester,
      onMoved: moved.add,
      child: _panel(() => taps++),
    );

    final Offset before =
        tester.getTopLeft(find.byKey(const Key('probe-btn')));
    final TestGesture gesture =
        await tester.startGesture(before + const Offset(20, 24));
    await tester.pump(const Duration(milliseconds: 20));
    // 第一次 move 超 slop（accept + onStart，不发 update）；后续 move 触发
    // onPanUpdate（真实交互为连续 move 事件）。
    await gesture.moveBy(const Offset(-20, -12));
    await tester.pump();
    await gesture.moveBy(const Offset(-100, -68));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final Offset after =
        tester.getTopLeft(find.byKey(const Key('probe-btn')));
    expect(after.dx, closeTo(before.dx - 100, 0.5));
    expect(after.dy, closeTo(before.dy - 68, 0.5));
    expect(moved, isNotEmpty);
    expect(taps, 0);
  });

  testWidgets('拖动被 clamp 在父约束内（左上角不越界）', (WidgetTester tester) async {
    await _pumpOverlay(tester, child: _panel(() => 0));

    final Offset before =
        tester.getTopLeft(find.byKey(const Key('probe-btn')));
    final TestGesture gesture =
        await tester.startGesture(before + const Offset(20, 24));
    await tester.pump(const Duration(milliseconds: 20));
    // 连续大步拖向左上：面板应停在 padding（16）处。
    for (int i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(-400, -300));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    final Rect panel = tester.getRect(find.byType(Column).last);
    expect(panel.left, closeTo(16, 0.5));
    expect(panel.top, closeTo(16, 0.5));
  });

  testWidgets('topLeft 对齐：初始位置即 padding 边距', (WidgetTester tester) async {
    await _pumpOverlay(
      tester,
      alignment: Alignment.topLeft,
      child: _panel(() => 0),
    );

    final Rect panel = tester.getRect(find.byType(Column).last);
    expect(panel.left, closeTo(16, 0.5));
    expect(panel.top, closeTo(16, 0.5));
  });
}
