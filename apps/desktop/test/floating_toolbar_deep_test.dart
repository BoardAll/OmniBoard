/// 可扩展工具栏深度测试（Wave3-3.3）。
///
/// 覆盖《可扩展工具栏设计 v1.0》：
/// - §3.1 主工具栏：9 类工具 + 撤销 / 重做 / 更多、当前工具高亮、
///   快捷键角标（仅显示）；
/// - §4 上下文切换：Provider 选区驱动、单选类型解析、多选工具栏；
/// - §6–16 上下文条目：颜色 / 单选 / 线宽弹层、删除二次确认；
/// - §11.2 待应用样式（选色再点表面，Esc / 取消退出）；
/// - §17 浮层：对象上方 / 翻转 / 点击空白收起 / 句柄关闭；
/// - §17.2 / §18 响应式溢出折叠（320 / 360 / 1280 宽）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/state/board_state.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/floating_toolbar.dart';
import 'package:whiteboard_desktop/widgets/toolbar/color_picker_popover.dart';
import 'package:whiteboard_desktop/widgets/toolbar/context_toolbar.dart';
import 'package:whiteboard_desktop/widgets/toolbar/toolbar_config.dart';
import 'package:whiteboard_desktop/widgets/toolbar/toolbar_item.dart';
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

/// 主题挂载壳（底部居中，与 board_edit_page 的挂载位置一致）。
Widget _themed(Widget child) {
  return MaterialApp(
    theme: kCleanProfessionalTheme.toFlutterThemeData(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: child,
        ),
      ),
    ),
  );
}

/// 带 Provider（演示模式白板 + 选区）的挂载壳。
Widget _providers({required Widget child, WbSelectionState? selection}) {
  final WbSelectionState sel = selection ?? WbSelectionState();
  if (selection == null) {
    addTearDown(sel.dispose);
  }
  return MultiProvider(
    providers: <SingleChildWidget>[
      ChangeNotifierProvider<WbBoardState>(
        create: (BuildContext context) => WbBoardState(ffi: _demoFfi()),
      ),
      ChangeNotifierProvider<WbSelectionState>.value(value: sel),
    ],
    child: child,
  );
}

/// 挂载（withProviders=true 时含 Provider）。
Future<void> _pump(
  WidgetTester tester,
  Widget widget, {
  Size size = const Size(1280, 800),
  bool withProviders = true,
  WbSelectionState? selection,
}) async {
  _setSurface(tester, size: size);
  await tester.pumpWidget(_themed(
    withProviders ? _providers(child: widget, selection: selection) : widget,
  ));
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Finder _toolKey(String id) => _key('wb-toolbar-$id');

Finder _contextKey(String id) => _key('wb-context-$id');

/// 读取工具栏按钮的渲染数据。
WbToolbarIconButton _button(WidgetTester tester, Finder finder) {
  return tester.widget<WbToolbarIconButton>(finder);
}

class _CommandLog {
  final List<WbToolbarCommand> commands = <WbToolbarCommand>[];
  final List<WbPendingStyle?> pendingChanges = <WbPendingStyle?>[];

  void onCommand(WbToolbarCommand command) => commands.add(command);

  void onPending(WbPendingStyle? style) => pendingChanges.add(style);

  WbToolbarCommand get last => commands.last;
}

void main() {
  group('配置与溢出算法（纯函数）', () {
    test('可见数量：320→4 / 360→5 / 472→9 / 无限→全显 / 空→0', () {
      int count(double width, int total) => computeWbToolbarVisibleCount(
            maxWidth: width - 16,
            padding: 0,
            leadingExtent: 0,
            fixedExtent: 120,
            itemExtent: WbToolbarMetrics.itemExtent,
            total: total,
          );

      expect(count(320, 9), 4);
      expect(count(360, 9), 5);
      expect(count(468, 9), 8);
      expect(count(472, 9), 9);
      expect(count(1280, 9), 9);
      expect(count(double.infinity, 9), 9);
      expect(count(320, 0), 0);
    });

    test('目录完整性：9 工具 / 15 类型 spec / none 为空', () {
      expect(WbMainToolbar.tools.length, 9);
      expect(
        WbMainToolbar.tools.map((WbToolbarItem item) => item.id).toList(),
        <String>[
          'select',
          'hand',
          'pen',
          'highlighter',
          'eraser',
          'sticky',
          'text',
          'shape',
          'image',
        ],
      );
      for (final WbContextToolbarSpec spec in WbContextCatalog.all) {
        if (spec.type == WbContextTargetType.none) {
          expect(spec.items, isEmpty);
        } else {
          expect(spec.items, isNotEmpty, reason: '${spec.type.id} 应有条目');
        }
      }
      expect(WbContextCatalog.specFor(WbContextTargetType.multiSelect).items.length, 11);
      // 多选工具栏覆盖单选层级功能：moreItems 含复制（duplicate）。
      final WbContextToolbarSpec multi =
          WbContextCatalog.specFor(WbContextTargetType.multiSelect);
      expect(
        multi.moreItems.map((WbContextItem item) => item.id).toList(),
        contains('duplicate'),
      );
    });
  });

  group('主工具栏（声明式 + 交互）', () {
    testWidgets('默认渲染：9 工具 + 撤销/重做/更多 + 选择高亮 + 快捷键角标',
        (WidgetTester tester) async {
      await _pump(tester, const FloatingToolbar());

      for (final WbToolbarItem item in WbMainToolbar.tools) {
        expect(_toolKey(item.id), findsOneWidget, reason: '缺少 ${item.id}');
      }
      expect(_toolKey('edit.undo'), findsOneWidget);
      expect(_toolKey('edit.redo'), findsOneWidget);
      expect(_key('wb-toolbar-more'), findsOneWidget);

      // 当前工具高亮：默认 select。
      expect(_button(tester, _toolKey('select')).active, isTrue);
      expect(_button(tester, _toolKey('pen')).active, isFalse);

      // 快捷键角标（仅显示提示）。
      const Map<String, String> badges = <String, String>{
        'select': 'V',
        'hand': 'H',
        'pen': 'P',
        'highlighter': 'M',
        'eraser': 'E',
        'sticky': 'N',
        'text': 'T',
        'shape': 'R',
        'image': 'I',
      };
      badges.forEach((String id, String badge) {
        expect(
          find.descendant(of: _toolKey(id), matching: find.text(badge)),
          findsOneWidget,
          reason: '$id 缺少角标 $badge',
        );
      });
    });

    testWidgets('点击工具：高亮切换 + onToolChanged 回调', (WidgetTester tester) async {
      final List<String> changed = <String>[];
      await _pump(
        tester,
        FloatingToolbar(onToolChanged: changed.add),
      );

      await tester.tap(_toolKey('pen'));
      await tester.pumpAndSettle();

      expect(_button(tester, _toolKey('pen')).active, isTrue);
      expect(_button(tester, _toolKey('select')).active, isFalse);
      expect(changed, <String>['pen']);

      // 重复点击仍回调（幂等选择）。
      await tester.tap(_toolKey('pen'));
      await tester.pumpAndSettle();
      expect(changed, <String>['pen', 'pen']);
    });

    testWidgets('受控模式：activeTool 固定高亮、点击只回调', (WidgetTester tester) async {
      final List<String> changed = <String>[];
      await _pump(
        tester,
        FloatingToolbar(
          activeTool: 'shape',
          onToolChanged: changed.add,
        ),
      );

      expect(_button(tester, _toolKey('shape')).active, isTrue);

      await tester.tap(_toolKey('text'));
      await tester.pumpAndSettle();

      // 受控：高亮保持 shape；回调仍发出。
      expect(_button(tester, _toolKey('shape')).active, isTrue);
      expect(_button(tester, _toolKey('text')).active, isFalse);
      expect(changed, <String>['text']);
    });

    testWidgets('无 Provider（演示模式）：渲染完整、撤销/重做灰显、点击不崩溃',
        (WidgetTester tester) async {
      await _pump(tester, const FloatingToolbar(), withProviders: false);

      expect(_toolKey('select'), findsOneWidget);
      expect(_button(tester, _toolKey('edit.undo')).enabled, isFalse);
      expect(_button(tester, _toolKey('edit.redo')).enabled, isFalse);

      // 点击无副作用、无异常。
      await tester.tap(_toolKey('select'));
      await tester.tap(_toolKey('edit.undo'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('有 Provider：撤销/重做可用且点击不崩溃（演示 no-op）',
        (WidgetTester tester) async {
      await _pump(tester, const FloatingToolbar());

      expect(_button(tester, _toolKey('edit.undo')).enabled, isTrue);
      expect(_button(tester, _toolKey('edit.redo')).enabled, isTrue);

      await tester.tap(_toolKey('edit.undo'));
      await tester.tap(_toolKey('edit.redo'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄窗 320：折叠为 4 项可见，更多菜单承接折叠工具', (WidgetTester tester) async {
      final List<String> changed = <String>[];
      await _pump(
        tester,
        FloatingToolbar(onToolChanged: changed.add),
        size: const Size(320, 480),
      );

      // 前缀 4 项可见。
      expect(_toolKey('select'), findsOneWidget);
      expect(_toolKey('hand'), findsOneWidget);
      expect(_toolKey('pen'), findsOneWidget);
      expect(_toolKey('highlighter'), findsOneWidget);
      expect(_toolKey('eraser'), findsNothing);
      expect(_toolKey('image'), findsNothing);

      // 固定尾部始终保留，更多按钮高亮提示折叠。
      expect(_toolKey('edit.undo'), findsOneWidget);
      expect(_key('wb-toolbar-more'), findsOneWidget);
      expect(
        tester.widget<WbToolbarMoreButton>(find.byType(WbToolbarMoreButton)).active,
        isTrue,
      );

      // 打开更多 → 折叠项可见 → 点击可选中（回调）。
      await tester.tap(_key('wb-toolbar-more'));
      await tester.pumpAndSettle();
      expect(_key('wb-toolbar-more-item-eraser'), findsOneWidget);
      expect(_key('wb-toolbar-more-item-sticky'), findsOneWidget);

      await tester.tap(_key('wb-toolbar-more-item-eraser'));
      await tester.pumpAndSettle();
      expect(changed, <String>['eraser']);
    });

    testWidgets('宽窗 1280：全部可见、更多不激活、设置/快捷键发命令',
        (WidgetTester tester) async {
      final List<WbToolbarCommand> commands = <WbToolbarCommand>[];
      await _pump(
        tester,
        FloatingToolbar(onCommand: commands.add),
      );

      expect(_toolKey('image'), findsOneWidget);
      expect(
        tester.widget<WbToolbarMoreButton>(find.byType(WbToolbarMoreButton)).active,
        isFalse,
      );

      await tester.tap(_key('wb-toolbar-more'));
      await tester.pumpAndSettle();
      expect(_key('wb-toolbar-more-item-app.settings'), findsOneWidget);
      expect(_key('wb-toolbar-more-item-app.shortcuts'), findsOneWidget);
      // 无折叠工具项。
      expect(_key('wb-toolbar-more-item-pen'), findsNothing);

      await tester.tap(_key('wb-toolbar-more-item-app.settings'));
      await tester.pumpAndSettle();
      expect(commands.single.toolId, 'app.settings');
    });
  });

  group('上下文切换（Provider 选区驱动）', () {
    testWidgets('选区驱动：空 → 主工具栏；单选未知 → 通用集；清空 → 恢复',
        (WidgetTester tester) async {
      final WbSelectionState selection = WbSelectionState();
      addTearDown(selection.dispose);
      await _pump(
        tester,
        const FloatingToolbar(),
        selection: selection,
      );

      expect(_toolKey('select'), findsOneWidget);
      expect(_contextKey('type-label'), findsNothing);

      // 单选（无解析器）→ unknown 通用集。
      selection.select(<String>['e1']);
      await tester.pumpAndSettle();
      expect(_toolKey('select'), findsNothing);
      expect(_contextKey('type-label'), findsOneWidget);
      expect(find.text('元素'), findsOneWidget);
      expect(_contextKey('delete'), findsOneWidget);

      // 清空 → 恢复主工具栏。
      selection.clear();
      await tester.pumpAndSettle();
      expect(_toolKey('select'), findsOneWidget);
      expect(_contextKey('type-label'), findsNothing);
    });

    testWidgets('类型解析器：便签 / 形状切换', (WidgetTester tester) async {
      final WbSelectionState selection = WbSelectionState();
      addTearDown(selection.dispose);
      await _pump(
        tester,
        FloatingToolbar(
          contextTypeResolver: (String id) => id == 'n1'
              ? WbContextTargetType.note
              : WbContextTargetType.shape,
        ),
        selection: selection,
      );

      selection.select(<String>['n1']);
      await tester.pumpAndSettle();
      expect(find.text('便签'), findsOneWidget);
      expect(_contextKey('font-size'), findsOneWidget);

      selection.select(<String>['s1']);
      await tester.pumpAndSettle();
      expect(find.text('形状'), findsOneWidget);
      expect(_contextKey('fill'), findsOneWidget);
    });
  });

  group('上下文工具栏条目与弹层', () {
    testWidgets('便签条目集：颜色 / 字号 / 对齐 / 标签 / 评论 + 类型标签',
        (WidgetTester tester) async {
      await _pump(
        tester,
        const WbContextToolbar(
          target: WbContextTarget(type: WbContextTargetType.note),
        ),
        withProviders: false,
      );

      expect(_contextKey('type-label'), findsOneWidget);
      expect(find.text('便签'), findsOneWidget);
      for (final String id in <String>[
        'color',
        'font-size',
        'align',
        'tag',
        'comment',
      ]) {
        expect(_contextKey(id), findsOneWidget, reason: '缺少便签条目 $id');
      }
      expect(_contextKey('more'), findsOneWidget);
    });

    testWidgets('颜色条目：弹层 12 色 + 主题 + 自定义 → element.setColor 命令',
        (WidgetTester tester) async {
      final _CommandLog log = _CommandLog();
      await _pump(
        tester,
        WbContextToolbar(
          target: const WbContextTarget(type: WbContextTargetType.note),
          onCommand: log.onCommand,
        ),
        withProviders: false,
      );

      await tester.tap(_contextKey('color'));
      await tester.pumpAndSettle();

      // 预设 12 色 + 主题色 + 自定义输入。
      for (int i = 0; i < 12; i++) {
        expect(_key('wb-color-swatch-$i'), findsOneWidget);
      }
      expect(_key('wb-color-swatch-theme'), findsOneWidget);
      expect(_key('wb-color-custom-input'), findsOneWidget);

      await tester.tap(_key('wb-color-swatch-2'));
      await tester.pumpAndSettle();

      expect(log.commands.single.toolId, 'element.setColor');
      expect(log.commands.single.args['color'], '#FFE5484D');
      expect(log.commands.single.args['slot'], 'note');
      expect(log.pendingChanges, isEmpty);
    });

    testWidgets('自定义颜色输入：非法不应用、合法应用', (WidgetTester tester) async {
      final _CommandLog log = _CommandLog();
      await _pump(
        tester,
        WbContextToolbar(
          target: const WbContextTarget(type: WbContextTargetType.text),
          onCommand: log.onCommand,
        ),
        withProviders: false,
      );

      await tester.tap(_contextKey('color'));
      await tester.pumpAndSettle();

      await tester.enterText(_key('wb-color-custom-input'), 'zzzz');
      await tester.pumpAndSettle();
      expect(log.commands, isEmpty); // 非法不应用

      await tester.enterText(_key('wb-color-custom-input'), '#12A150');
      await tester.pumpAndSettle();
      await tester.tap(_key('wb-color-custom-apply'));
      await tester.pumpAndSettle();

      expect(log.commands.single.toolId, 'element.setColor');
      expect(log.commands.single.args['color'], '#FF12A150');
      expect(log.commands.single.args['slot'], 'text');
    });

    testWidgets('单选条目（字号）：弹层选项 → element.setFontSize + 参数',
        (WidgetTester tester) async {
      final _CommandLog log = _CommandLog();
      await _pump(
        tester,
        WbContextToolbar(
          target: const WbContextTarget(type: WbContextTargetType.note),
          onCommand: log.onCommand,
        ),
        withProviders: false,
      );

      await tester.tap(_contextKey('font-size'));
      await tester.pumpAndSettle();
      expect(_key('wb-choice-24'), findsOneWidget);

      await tester.tap(_key('wb-choice-24'));
      await tester.pumpAndSettle();

      expect(log.commands.single.toolId, 'element.setFontSize');
      expect(log.commands.single.args['value'], '24');
      expect(log.commands.single.args['size'], 24);
    });

    testWidgets('线宽条目（连线）：弹层档位 → element.setLineWidth + width',
        (WidgetTester tester) async {
      final _CommandLog log = _CommandLog();
      await _pump(
        tester,
        WbContextToolbar(
          target: const WbContextTarget(type: WbContextTargetType.connector),
          onCommand: log.onCommand,
        ),
        withProviders: false,
      );

      await tester.tap(_contextKey('line-width'));
      await tester.pumpAndSettle();
      expect(_key('wb-line-width-2'), findsOneWidget);

      await tester.tap(_key('wb-line-width-2'));
      await tester.pumpAndSettle();

      expect(log.commands.single.toolId, 'element.setLineWidth');
      expect(log.commands.single.args['width'], 8);
    });

    testWidgets('多选工具栏：对齐 / 分布 / 分组条目 → element.align 命令',
        (WidgetTester tester) async {
      final _CommandLog log = _CommandLog();
      await _pump(
        tester,
        WbContextToolbar(
          target: const WbContextTarget(
            type: WbContextTargetType.multiSelect,
            count: 3,
          ),
          onCommand: log.onCommand,
        ),
        withProviders: false,
      );

      expect(find.text('多选 ×3'), findsOneWidget);
      for (final String id in <String>[
        'align-left',
        'align-hcenter',
        'align-right',
        'align-top',
        'align-vcenter',
        'align-bottom',
        'distribute-h',
        'distribute-v',
        'color',
        'group',
        'ungroup',
      ]) {
        expect(_contextKey(id), findsOneWidget, reason: '缺少多选条目 $id');
      }

      await tester.tap(_contextKey('align-left'));
      await tester.pumpAndSettle();
      expect(log.commands.single.toolId, 'element.align');
      expect(log.commands.single.args['align'], 'left');
    });

    testWidgets('更多菜单：删除需二次确认（取消不发命令 / 确认发出）',
        (WidgetTester tester) async {
      final _CommandLog log = _CommandLog();
      await _pump(
        tester,
        WbContextToolbar(
          target: const WbContextTarget(type: WbContextTargetType.shape),
          onCommand: log.onCommand,
        ),
        withProviders: false,
      );

      // 取消路径。
      await tester.tap(_contextKey('more'));
      await tester.pumpAndSettle();
      await tester.tap(_key('wb-toolbar-more-item-delete'));
      await tester.pumpAndSettle();
      expect(_key('wb-delete-confirm'), findsOneWidget);
      await tester.tap(_key('wb-delete-confirm-cancel'));
      await tester.pumpAndSettle();
      expect(log.commands, isEmpty);

      // 确认路径。
      await tester.tap(_contextKey('more'));
      await tester.pumpAndSettle();
      await tester.tap(_key('wb-toolbar-more-item-delete'));
      await tester.pumpAndSettle();
      await tester.tap(_key('wb-delete-confirm-ok'));
      await tester.pumpAndSettle();

      expect(log.commands.single.toolId, 'element.delete');
    });

    testWidgets('窄屏上下文溢出：条目折叠入更多菜单', (WidgetTester tester) async {
      await _pump(
        tester,
        const FloatingToolbar(
          contextTarget: WbContextTarget(
            type: WbContextTargetType.multiSelect,
            count: 3,
          ),
        ),
        size: const Size(260, 480),
      );

      // 前缀 2 项可见（对齐左 / 水平居中），其余折叠。
      expect(_contextKey('align-left'), findsOneWidget);
      expect(_contextKey('align-hcenter'), findsOneWidget);
      expect(_contextKey('align-right'), findsNothing);
      expect(_contextKey('group'), findsNothing);

      await tester.tap(_contextKey('more'));
      await tester.pumpAndSettle();
      expect(_key('wb-toolbar-more-item-group'), findsOneWidget);
      expect(_key('wb-toolbar-more-item-align-right'), findsOneWidget);
    });
  });

  group('待应用样式（选色再点表面，§11.2）', () {
    testWidgets('3D 选色 → armed → Esc 取消', (WidgetTester tester) async {
      final _CommandLog log = _CommandLog();
      await _pump(
        tester,
        WbContextToolbar(
          target: const WbContextTarget(type: WbContextTargetType.render3d),
          onCommand: log.onCommand,
          onPendingChanged: log.onPending,
        ),
        withProviders: false,
      );

      await tester.tap(_contextKey('face-color'));
      await tester.pumpAndSettle();
      await tester.tap(_key('wb-color-swatch-2'));
      await tester.pumpAndSettle();

      // 进入待应用状态：状态条出现 + armed 命令 + 回调。
      expect(_key('wb-toolbar-pending'), findsOneWidget);
      expect(log.last.toolId, 'render.3d.setFaceColor');
      expect(log.last.args['mode'], 'armed');
      expect(log.last.args['color'], '#FFE5484D');
      expect(log.last.args['slot'], 'face');
      expect(log.pendingChanges.last?.toolId, 'render.3d.setFaceColor');

      // Esc 退出。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_key('wb-toolbar-pending'), findsNothing);
      expect(log.last.args['mode'], 'cancel');
      expect(log.pendingChanges.last, isNull);
      expect(log.commands.length, 2);
    });

    testWidgets('3D 选色 → 取消按钮退出', (WidgetTester tester) async {
      final _CommandLog log = _CommandLog();
      await _pump(
        tester,
        WbContextToolbar(
          target: const WbContextTarget(type: WbContextTargetType.render3d),
          onCommand: log.onCommand,
          onPendingChanged: log.onPending,
        ),
        withProviders: false,
      );

      await tester.tap(_contextKey('face-color'));
      await tester.pumpAndSettle();
      await tester.tap(_key('wb-color-swatch-0'));
      await tester.pumpAndSettle();
      expect(_key('wb-toolbar-pending'), findsOneWidget);

      await tester.tap(_key('wb-toolbar-pending-cancel'));
      await tester.pumpAndSettle();

      expect(_key('wb-toolbar-pending'), findsNothing);
      expect(log.last.args['mode'], 'cancel');
      expect(log.pendingChanges.last, isNull);
    });
  });

  group('上下文浮层（§17）', () {
    testWidgets('出现于对象上方、setVisible 隐藏-恢复、close 销毁', (WidgetTester tester) async {
      WbContextToolbarHandle? handle;
      await _pump(
        tester,
        Builder(
          builder: (BuildContext context) {
            return TextButton(
              onPressed: () {
                handle = showWbContextToolbar(
                  context,
                  target: const WbContextTarget(type: WbContextTargetType.shape),
                  anchor: const Rect.fromLTWH(300, 300, 120, 60),
                );
              },
              child: const Text('open'),
            );
          },
        ),
        withProviders: false,
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(_key('wb-context-toolbar-popup'), findsOneWidget);

      // 默认对象上方：弹层底边 ≤ 锚点顶边。
      final Rect popupRect = tester.getRect(_key('wb-context-toolbar-popup'));
      expect(popupRect.bottom, lessThanOrEqualTo(300.0));
      expect(popupRect.center.dx, closeTo(360, 80));

      // setVisible(false) → Offstage 保活隐藏（不销毁）；setVisible(true) 恢复。
      handle!.setVisible(false);
      await tester.pumpAndSettle();
      expect(_key('wb-context-toolbar-popup'), findsNothing);
      expect(handle!.isClosed, isFalse);
      handle!.setVisible(true);
      await tester.pumpAndSettle();
      expect(_key('wb-context-toolbar-popup'), findsOneWidget);

      // close() 终极销毁：entry 移除、句柄关闭。
      handle!.close();
      await tester.pumpAndSettle();
      expect(_key('wb-context-toolbar-popup'), findsNothing);
      expect(handle!.isClosed, isTrue);

      // 重新打开（新句柄）→ 再次显示；close() 收尾。
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(_key('wb-context-toolbar-popup'), findsOneWidget);
      expect(handle!.isClosed, isFalse);
      handle!.close();
      await tester.pumpAndSettle();
      expect(_key('wb-context-toolbar-popup'), findsNothing);
      expect(handle!.isClosed, isTrue);
    });

    testWidgets('空间不足翻转对象下方（§17.1）', (WidgetTester tester) async {
      await _pump(
        tester,
        Builder(
          builder: (BuildContext context) {
            return TextButton(
              onPressed: () {
                showWbContextToolbar(
                  context,
                  target:
                      const WbContextTarget(type: WbContextTargetType.connector),
                  anchor: const Rect.fromLTWH(400, 20, 140, 40),
                );
              },
              child: const Text('open'),
            );
          },
        ),
        withProviders: false,
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final Rect popupRect = tester.getRect(_key('wb-context-toolbar-popup'));
      // 下方：顶边 ≈ 锚点底边 60 + 间距 12。
      expect(popupRect.top, closeTo(72, 1));
    });

    testWidgets('空目标：不显示浮层', (WidgetTester tester) async {
      await _pump(
        tester,
        Builder(
          builder: (BuildContext context) {
            return TextButton(
              onPressed: () {
                showWbContextToolbar(
                  context,
                  target:
                      const WbContextTarget(type: WbContextTargetType.none, count: 0),
                );
              },
              child: const Text('open'),
            );
          },
        ),
        withProviders: false,
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(_key('wb-context-toolbar-popup'), findsNothing);
    });
  });
}
