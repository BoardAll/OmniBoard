/// 齿轮圆盘深度交互测试（Wave3-3.1）。
///
/// 覆盖《齿轮圆盘交互详细设计 v1.1》：内外环布局、拖拽选中（含轨迹线 /
/// 回拖取消 / 子环自动展开）、子工具扇形展开、长按锁定、右键配置入口、
/// 键盘导航、最近使用、隐藏恢复、小屏适配、减少动效与临时弹出。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kSecondaryButton, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/state/board_state.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/radial/radial_item.dart';
import 'package:whiteboard_desktop/widgets/radial/radial_layout.dart';
import 'package:whiteboard_desktop/widgets/radial/radial_menu.dart';
import 'package:whiteboard_desktop/widgets/radial/radial_models.dart';
import 'package:whiteboard_desktop/widgets/radial/radial_popup.dart';
import 'package:whiteboard_desktop/widgets/radial/radial_trail.dart';
import 'package:whiteboard_desktop/widgets/radial_toolbar.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

/// 构造演示模式 FFI 服务（候选路径必然失败，保证测试确定性）。
WbFfiService _demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

/// 固定测试画布尺寸。
void _setSurface(WidgetTester tester, {Size size = const Size(1280, 800)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 带主题（含 Provider）的挂载壳：与 board_edit_page 的挂载位置一致。
Widget _harness(Widget child) {
  return MultiProvider(
    providers: <SingleChildWidget>[
      ChangeNotifierProvider<WbBoardState>(
        create: (BuildContext context) => WbBoardState(ffi: _demoFfi()),
      ),
      ChangeNotifierProvider<WbSelectionState>(
        create: (BuildContext context) => WbSelectionState(),
      ),
    ],
    child: _themed(child),
  );
}

/// 仅主题（无 Provider）：用于演示模式安全性断言。
Widget _themed(Widget child) {
  return MaterialApp(
    theme: kCleanProfessionalTheme.toFlutterThemeData(),
    home: Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned(right: 20, bottom: 96, child: child),
        ],
      ),
    ),
  );
}

Finder get _center => find.byKey(const ValueKey<String>('radial-center'));
Finder _inner(String id) => find.byKey(ValueKey<String>('radial-inner-$id'));
Finder _group(String id) => find.byKey(ValueKey<String>('radial-group-$id'));
Finder _sub(String id) => find.byKey(ValueKey<String>('radial-sub-$id'));
Finder _recent(String id) => find.byKey(ValueKey<String>('radial-recent-$id'));

Future<void> _pumpToolbar(
  WidgetTester tester,
  Widget toolbar, {
  Size size = const Size(1280, 800),
}) async {
  _setSurface(tester, size: size);
  await tester.pumpWidget(_harness(toolbar));
}

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(_center);
  await tester.pumpAndSettle();
}

/// 越过失焦/双击等待窗口后落定（单击外环有 300ms 双击宽限）。
Future<void> _settleTap(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

RadialTrailPainter _trailPainter(WidgetTester tester) {
  final CustomPaint paint = tester
      .widget<CustomPaint>(find.byKey(const ValueKey<String>('radial-trail')));
  return paint.painter! as RadialTrailPainter;
}

void main() {
  group('目录与几何（纯函数单元）', () {
    test('内环 6 / 外环 8 / 角度与环带命中 / 子槽往返', () {
      expect(RadialCatalog.inner.length, 6);
      expect(RadialCatalog.groups.length, 8);
      expect(RadialCatalog.inner[5].isAction, isTrue);
      expect(RadialCatalog.groups[2].tools.length, 6);
      expect(RadialCatalog.groups[7].tools.last.id, kRadialSettingsId);

      // 第 0 项在正上方（-π/2），顺时针。
      expect(angleForIndex(0, 8), closeTo(-math.pi / 2, 1e-9));
      expect(angleForIndex(2, 8), closeTo(0, 1e-9));

      const RadialMetrics metrics = RadialMetrics();
      expect(zoneForRadius(10, metrics), RadialZone.none);
      expect(zoneForRadius(40, metrics), RadialZone.inner);
      expect(zoneForRadius(100, metrics), RadialZone.outer);
      expect(zoneForRadius(140, metrics), RadialZone.sub);
      expect(metrics.frame, 360);
      expect(metrics.discDiameter, 240);

      // 子环槽位与角度互逆（6 槽满窗口）。
      final double groupAngle = angleForIndex(2, 8);
      for (int slot = 0; slot < 6; slot++) {
        final double angle = subSlotAngle(groupAngle, slot, 6);
        expect(subSlotForAngle(angle, groupAngle, 6), slot);
      }
      // 弧外返回 null（容差之外）。
      expect(subSlotForAngle(groupAngle + 1.2, groupAngle, 6), isNull);

      // 滚动夹取（>6 才可能滚动）。
      expect(subScrollMax(7), 1);
      expect(clampSubScroll(5, 7), 1);
      expect(clampSubScroll(-2, 7), 0);
      expect(clampSubScroll(3, 4), 0);
    });
  });

  group('齿轮圆盘基础交互', () {
    testWidgets('对外构造兼容（const 无参）：默认收起且条目不可点', (WidgetTester tester) async {
      await _pumpToolbar(tester, const RadialToolbar());

      expect(_center, findsOneWidget);
      // 收起：中心显示当前工具（选择），不是齿轮。
      expect(
        find.descendant(of: _center, matching: find.byIcon(LinearIcons.select)),
        findsOneWidget,
      );
      // 环条目存在但 IgnorePointer 屏蔽命中。
      expect(_inner('select').hitTestable(), findsNothing);
      expect(_recent('select').hitTestable(), findsNothing);
      expect(
          find.byKey(const ValueKey<String>('radial-sub-rect')), findsNothing);
    });

    testWidgets('单击中心：展开显示内外环与最近使用，再点收起', (WidgetTester tester) async {
      await _pumpToolbar(tester, const RadialToolbar());
      await _expand(tester);

      expect(_inner('select').hitTestable(), findsOneWidget);
      expect(_group('shape-link').hitTestable(), findsOneWidget);
      expect(_recent('select').hitTestable(), findsOneWidget);
      expect(_recent('shape').hitTestable(), findsOneWidget);
      expect(
        find.descendant(of: _center, matching: find.byIcon(LinearIcons.grid)),
        findsOneWidget,
      );

      await tester.tap(_center);
      await tester.pumpAndSettle();
      expect(_inner('select').hitTestable(), findsNothing);
      expect(
        find.descendant(of: _center, matching: find.byIcon(LinearIcons.select)),
        findsOneWidget,
      );
    });

    testWidgets('单击内环：选中、收起、中心图标与最近使用联动', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await _pumpToolbar(tester, RadialToolbar(onToolSelected: selected.add));
      await _expand(tester);

      await tester.tap(_inner('sticky'));
      await tester.pumpAndSettle();

      expect(selected, <String>['sticky']);
      expect(_inner('sticky').hitTestable(), findsNothing);
      expect(
        find.descendant(
          of: _center,
          matching: find.byIcon(LinearIcons.stickyNote),
        ),
        findsOneWidget,
      );

      // 最近使用置顶 + 当前工具高亮。
      await _expand(tester);
      final RadialRecentBar bar =
          tester.widget<RadialRecentBar>(find.byType(RadialRecentBar));
      expect(bar.tools.first.id, 'sticky');
      expect(bar.tools.length, 3);
      expect(
          tester.widget<RadialItemButton>(_recent('sticky')).selected, isTrue);
      expect(
          tester.widget<RadialItemButton>(_inner('sticky')).selected, isTrue);
      expect(tester.widget<RadialItemButton>(_inner('pen')).selected, isFalse);
    });

    testWidgets('外环单击展开子扇形：同组收起、异组切换', (WidgetTester tester) async {
      await _pumpToolbar(tester, const RadialToolbar());
      await _expand(tester);

      await tester.tap(_group('note-text'));
      await _settleTap(tester);
      expect(_sub('sticky').hitTestable(), findsOneWidget);
      expect(_sub('text').hitTestable(), findsOneWidget);
      // 展开分组后其他扇区变暗（透明度 40%）。
      expect(
          tester.widget<RadialItemButton>(_group('shape-link')).dimmed, isTrue);
      expect(
          tester.widget<RadialItemButton>(_group('note-text')).dimmed, isFalse);

      // 单击同组 → 收起子工具。
      await tester.tap(_group('note-text'));
      await _settleTap(tester);
      expect(find.byKey(const ValueKey<String>('radial-sub-sticky')),
          findsNothing);

      // 切换到形状 / 连线组。
      await tester.tap(_group('shape-link'));
      await _settleTap(tester);
      expect(_sub('rect').hitTestable(), findsOneWidget);
      expect(_sub('connector').hitTestable(), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('radial-sub-sticky')),
          findsNothing);
    });

    testWidgets('外环双击：选中分组默认工具并收起', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await _pumpToolbar(tester, RadialToolbar(onToolSelected: selected.add));
      await _expand(tester);

      await tester.tap(_group('shape-link'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(_group('shape-link'));
      await tester.pumpAndSettle();

      expect(selected, <String>['rect']);
      expect(_inner('select').hitTestable(), findsNothing);
    });

    testWidgets('单击子工具：选中并收起，最近使用更新', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await _pumpToolbar(tester, RadialToolbar(onToolSelected: selected.add));
      await _expand(tester);

      await tester.tap(_group('pen-eraser'));
      await _settleTap(tester);
      await tester.tap(_sub('highlighter'));
      await tester.pumpAndSettle();

      expect(selected, <String>['highlighter']);
      expect(_inner('select').hitTestable(), findsNothing);
      await _expand(tester);
      final RadialRecentBar bar =
          tester.widget<RadialRecentBar>(find.byType(RadialRecentBar));
      expect(bar.tools.first.id, 'highlighter');
    });
  });

  group('拖拽选中（文档 5.2）', () {
    testWidgets('拖到内环松开：轨迹线指示名称 + 高亮 + 选中收起', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await _pumpToolbar(tester, RadialToolbar(onToolSelected: selected.add));
      await _expand(tester);

      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(_center));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();

      // 轨迹线（文档 5.2）：末端标签为指向项名称。
      expect(_trailPainter(tester).label, '选择');
      expect(tester.widget<RadialItemButton>(_inner('select')).highlighted,
          isTrue);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected, <String>['select']);
      expect(_inner('select').hitTestable(), findsNothing);
    });

    testWidgets('回拖取消：拖回中心松开 → 保持展开且不选中', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await _pumpToolbar(tester, RadialToolbar(onToolSelected: selected.add));
      await _expand(tester);

      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(_center));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 52));
      await tester.pump();

      expect(_trailPainter(tester).label, '取消');

      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(_inner('select').hitTestable(), findsOneWidget);
    });

    testWidgets('拖到子环带：自动展开分组并拖选子工具', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await _pumpToolbar(tester, RadialToolbar(onToolSelected: selected.add));
      await _expand(tester);

      final Offset center = tester.getCenter(_center);
      final TestGesture gesture = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 20));
      // 便签 / 文本组（-45°），子环半径 150 → 槽位 2 = 标题。
      await gesture.moveTo(center + const Offset(0, -90));
      await tester.pump();
      await gesture.moveTo(center + const Offset(106.1, -106.1));
      await tester.pump();

      expect(_sub('heading').hitTestable(), findsOneWidget);
      expect(_trailPainter(tester).label, '标题');

      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected, <String>['heading']);
      expect(_inner('select').hitTestable(), findsNothing);
    });
  });

  group('锁定与隐藏（文档 5.1 / 7.2）', () {
    testWidgets('长按中心：锁定（锁图标 + 常驻展开），再长按解锁', (WidgetTester tester) async {
      await _pumpToolbar(tester, const RadialToolbar());

      await tester.longPress(_center);
      await tester.pumpAndSettle();
      expect(find.byIcon(LinearIcons.lock), findsOneWidget);
      expect(_inner('select').hitTestable(), findsOneWidget);

      // 锁定态单击中心不收起。
      await tester.tap(_center);
      await tester.pumpAndSettle();
      expect(_inner('select').hitTestable(), findsOneWidget);

      await tester.longPress(_center);
      await tester.pumpAndSettle();
      expect(find.byIcon(LinearIcons.lock), findsNothing);
      expect(_inner('select').hitTestable(), findsNothing);
    });

    testWidgets('右键配置：隐藏圆盘 → 恢复把手 → 恢复', (WidgetTester tester) async {
      await _pumpToolbar(tester, const RadialToolbar());

      await tester.tap(_center,
          buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text('隐藏圆盘'), findsOneWidget);

      await tester.tap(find.text('隐藏圆盘'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey<String>('radial-restore')), findsOneWidget);
      expect(_center, findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('radial-restore')));
      await tester.pumpAndSettle();
      expect(_center, findsOneWidget);
      expect(_inner('select').hitTestable(), findsNothing);
    });

    testWidgets('右键配置：切换显示标签与尺寸档（联动生效）', (WidgetTester tester) async {
      await _pumpToolbar(tester, const RadialToolbar());
      await _expand(tester);
      expect(find.text('便签'), findsOneWidget);

      await tester.tap(_center,
          buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('显示标签'),
          kind: PointerDeviceKind.mouse, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('便签'), findsNothing);

      await tester.tap(_center,
          buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('大小：小'),
          kind: PointerDeviceKind.mouse, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tester.getSize(_center), const Size(42, 42));
    });
  });

  group('键盘操作（文档 5.4）', () {
    testWidgets('Space 展开/收起、Esc 收起、数字与字母快捷键', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await _pumpToolbar(tester, RadialToolbar(onToolSelected: selected.add));

      // 点中心获得焦点并展开。
      await _expand(tester);
      expect(_inner('select').hitTestable(), findsOneWidget);

      // Space 收起。
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(_inner('select').hitTestable(), findsNothing);

      // Space 再展开，Esc 收起。
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(_inner('select').hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_inner('select').hitTestable(), findsNothing);

      // 数字 3 → 形状。
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pumpAndSettle();
      expect(selected, <String>['shape']);

      // 字母 N → 便签。
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(selected, <String>['shape', 'sticky']);
    });

    testWidgets('方向键高亮 + Enter 展开分组并选中子工具', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await _pumpToolbar(tester, RadialToolbar(onToolSelected: selected.add));
      await _expand(tester);

      // → 二次：焦点落在「便签 / 文本」组。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
          tester.widget<RadialItemButton>(_group('note-text')).focused, isTrue);

      // Enter：展开该组子工具（焦点落到槽位 0 = 便签）。
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_sub('sticky').hitTestable(), findsOneWidget);

      // → 到「文本」，Enter 选中。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(tester.widget<RadialItemButton>(_sub('text')).focused, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, <String>['text']);
      expect(_sub('text').hitTestable(), findsNothing);
    });

    testWidgets('Tab 切换分组：子环随分组切换', (WidgetTester tester) async {
      await _pumpToolbar(tester, const RadialToolbar());
      await _expand(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_sub('select').hitTestable(), findsOneWidget); // 选择 / 手组

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_sub('sticky').hitTestable(), findsOneWidget); // 便签 / 文本组
      expect(find.byKey(const ValueKey<String>('radial-sub-select')),
          findsNothing);
    });
  });

  group('最近使用与更多菜单（文档 3.2 / 4）', () {
    testWidgets('默认三项、点击选中、配置清空', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await _pumpToolbar(tester, RadialToolbar(onToolSelected: selected.add));
      await _expand(tester);

      final RadialRecentBar bar =
          tester.widget<RadialRecentBar>(find.byType(RadialRecentBar));
      expect(
        bar.tools.map((RadialTool tool) => tool.id).toList(),
        <String>['select', 'sticky', 'shape'],
      );

      await tester.tap(_recent('sticky'));
      await tester.pumpAndSettle();
      expect(selected, <String>['sticky']);
      expect(_inner('select').hitTestable(), findsNothing);

      // 清空最近使用。
      await _expand(tester);
      await tester.tap(_center,
          buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空最近使用'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.byType(RadialRecentBar), findsNothing);
    });

    testWidgets('更多菜单：撤销走演示安全路径，AI 入口回调上报', (WidgetTester tester) async {
      final List<String> actions = <String>[];
      await _pumpToolbar(tester, RadialToolbar(onAction: actions.add));
      await _expand(tester);

      await tester.tap(_inner('more'));
      await tester.pumpAndSettle();
      expect(find.text('撤销'), findsOneWidget);
      expect(find.text('重做'), findsOneWidget);
      expect(find.text('AI 助手'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);

      // 撤销：演示模式 no-op，不崩溃、不走动作回调。
      await tester.tap(find.text('撤销'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(actions, isEmpty);

      // 再开一次：AI 助手上报 id。
      await tester.tap(_inner('more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI 助手'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(actions, <String>[kRadialAiAssistantId]);
    });

    testWidgets('无 Provider 环境下撤销入口不崩溃（演示模式安全）', (WidgetTester tester) async {
      _setSurface(tester);
      await tester.pumpWidget(_themed(const RadialToolbar()));

      await _expand(tester);
      await tester.tap(_inner('more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('动效 / 小屏 / 弹出', () {
    testWidgets('RadialMenu：animations=false 走零动效路径',
        (WidgetTester tester) async {
      _setSurface(tester);
      await tester.pumpWidget(_themed(
        const Center(
          child: SizedBox(
            width: 360,
            height: 360,
            child: RadialMenu(
              metrics: RadialMetrics(),
              expanded: true,
              animations: false,
              showRecent: false,
            ),
          ),
        ),
      ));
      expect(
        find.ancestor(
          of: _inner('select'),
          matching: find.byType(AnimatedOpacity),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(of: _inner('select'), matching: find.byType(Opacity)),
        findsWidgets,
      );

      // 开动效后：条目外层为 AnimatedOpacity。
      await tester.pumpWidget(_themed(
        const Center(
          child: SizedBox(
            width: 360,
            height: 360,
            child: RadialMenu(
              metrics: RadialMetrics(),
              expanded: true,
              showRecent: false,
            ),
          ),
        ),
      ));
      expect(
        find.ancestor(
          of: _inner('select'),
          matching: find.byType(AnimatedOpacity),
        ),
        findsWidgets,
      );
    });

    testWidgets('小屏适配：圆盘缩至 0.75、标签隐藏', (WidgetTester tester) async {
      await _pumpToolbar(
        tester,
        const RadialToolbar(),
        size: const Size(700, 900),
      );
      await _expand(tester);

      expect(tester.getSize(_center), const Size(42, 42));
      expect(find.text('便签'), findsNothing);
      expect(find.text('选择'), findsNothing);
    });

    testWidgets('RadialPopup：弹出后选中工具，关闭并回传 id', (WidgetTester tester) async {
      String? result;
      _setSurface(tester);
      await tester.pumpWidget(_themed(
        Builder(
          builder: (BuildContext context) {
            return ElevatedButton(
              onPressed: () {
                unawaited(RadialPopup.show(
                  context,
                  globalPosition: const Offset(400, 300),
                ).then((String? value) {
                  result = value;
                }));
              },
              child: const Text('弹出'),
            );
          },
        ),
      ));

      await tester.tap(find.text('弹出'), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(find.byType(RadialToolbar), findsOneWidget);
      expect(_inner('sticky').hitTestable(), findsOneWidget);

      await tester.tap(_inner('sticky'));
      await tester.pumpAndSettle();
      expect(find.byType(RadialToolbar), findsNothing);
      expect(result, 'sticky');
    });

    testWidgets('RadialPopup：无操作超时自动淡出', (WidgetTester tester) async {
      String? result = 'sentinel';
      _setSurface(tester);
      await tester.pumpWidget(_themed(
        Builder(
          builder: (BuildContext context) {
            return ElevatedButton(
              onPressed: () {
                unawaited(RadialPopup.show(
                  context,
                  globalPosition: const Offset(400, 300),
                  autoDismiss: const Duration(milliseconds: 600),
                ).then((String? value) {
                  result = value;
                }));
              },
              child: const Text('弹出'),
            );
          },
        ),
      ));

      await tester.tap(find.text('弹出'), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(find.byType(RadialToolbar), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(RadialToolbar), findsNothing);
      expect(result, isNull);
    });
  });
}
