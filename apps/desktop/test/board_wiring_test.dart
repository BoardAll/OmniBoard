/// 编辑页接线冒烟（Wave 3 协调者集成）：命令面板接棒 / 透明批注入口 /
/// 快速创建 / 长按空白画布弹临时圆盘。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/app.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/shortcut_service.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/services/theme_service.dart';
import 'package:whiteboard_desktop/state/theme_state.dart';
import 'package:whiteboard_desktop/widgets/ai_panel.dart';
import 'package:whiteboard_desktop/widgets/annotation/annotation_controller.dart';
import 'package:whiteboard_desktop/widgets/annotation/annotation_exit_dialog.dart';
import 'package:whiteboard_desktop/widgets/annotation/annotation_overlay.dart';
import 'package:whiteboard_desktop/widgets/annotation/annotation_toolbar.dart';
import 'package:whiteboard_desktop/widgets/command_palette.dart';
import 'package:whiteboard_desktop/widgets/context_editors/flowchart_editor.dart';
import 'package:whiteboard_desktop/widgets/guide/help_center.dart';
import 'package:whiteboard_desktop/widgets/radial_toolbar.dart';

/// 演示模式 FFI 服务（候选路径必然失败，保证测试确定性）。
WbFfiService _demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

/// 启动应用并进入编辑页（1600x1000 视口，与冒烟测试一致）。
Future<WbThemeState> _pumpEditor(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final WbThemeState theme = WbThemeState();
  final WbCollabService sync = WbCollabService();
  addTearDown(() {
    theme.dispose();
    sync.dispose();
  });

  await tester.pumpWidget(WhiteboardApp(
    ffiService: _demoFfi(),
    themeState: theme,
    collabService: sync,
    shortcutService: WbShortcutService(),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('新建白板'));
  await tester.pumpAndSettle();
  return theme;
}

void main() {
  testWidgets('快速创建：展开按钮条并打开流程图编辑器（独立编辑页）',
      (WidgetTester tester) async {
    await _pumpEditor(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-quick-create-toggle')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wb-ctx-quick-create-bar')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-quick-create-flowchart')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WbFlowchartEditor), findsOneWidget);

    // 取消（编辑页返回键）：回到白板页且不插入。
    await tester.tap(
      find.byKey(const ValueKey<String>('element-editor-cancel')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WbFlowchartEditor), findsNothing);
  });

  testWidgets('显示桌面：AppBar 入口进入桌面批注，退出后恢复主界面',
      (WidgetTester tester) async {
    // 模拟平台插件已注册：窗口能力通道返回成功，避免测试环境
    // （FakeAsync 无真实平台消息响应）阻塞退出链路。
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('whiteboard/windows'),
      (MethodCall call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) async {
        if (call.method == 'getBounds') {
          return <String, dynamic>{
            'x': 20.0,
            'y': 30.0,
            'width': 1600.0,
            'height': 1000.0,
          };
        }
        return null;
      },
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('whiteboard/windows'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
    });

    await _pumpEditor(tester);

    await tester.tap(find.byTooltip('显示桌面'));
    await tester.pumpAndSettle();

    // 批注组合层渲染；白板 AppBar（返回入口）与内容让位。
    expect(find.byType(AnnotationOverlay), findsOneWidget);
    expect(find.byType(AnnotationToolbar), findsOneWidget);
    expect(find.byTooltip('返回列表'), findsNothing);

    // 退出（丢弃）：恢复主界面。
    await tester.tap(
      find.byKey(const ValueKey<String>('annotation-exit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        WbAnnotationExitDialog.choiceKey(WbAnnotationExitChoice.discard),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AnnotationOverlay), findsNothing);
    expect(find.byTooltip('显示桌面'), findsOneWidget);
  });

  testWidgets('长按空白画布弹出临时圆盘，点击外部收起', (WidgetTester tester) async {
    await _pumpEditor(tester);
    expect(find.byType(RadialToolbar), findsOneWidget);

    final TestGesture gesture = await tester.startGesture(const Offset(760, 500));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(RadialToolbar), findsNWidgets(2));

    await gesture.up();
    await tester.pump();

    // 点击弹出层遮罩收起。
    await tester.tapAt(const Offset(760, 100));
    await tester.pumpAndSettle();
    expect(find.byType(RadialToolbar), findsOneWidget);
  });

  testWidgets('收起 AI 面板后 Ctrl+K 仍可唤起命令面板', (WidgetTester tester) async {
    await _pumpEditor(tester);

    await tester.tap(find.byTooltip('收起 AI 面板'));
    await tester.pumpAndSettle();
    expect(find.byType(AiPanel), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsOneWidget);

    // 点击遮罩关闭命令面板。
    await tester.tapAt(const Offset(30, 30));
    await tester.pumpAndSettle();
    expect(find.byType(CommandPalette), findsNothing);
  });

  testWidgets('帮助中心：AppBar 入口打开并可关闭', (WidgetTester tester) async {
    await _pumpEditor(tester);

    await tester.tap(find.byTooltip('帮助中心'));
    await tester.pumpAndSettle();
    expect(find.byType(WbHelpCenter), findsOneWidget);

    // 点击遮罩关闭帮助中心。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(WbHelpCenter), findsNothing);
  });

  testWidgets('快速创建：保存流程图编辑器后自动插入画布并提示（问题 6 / 9）',
      (WidgetTester tester) async {
    await _pumpEditor(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-quick-create-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-quick-create-flowchart')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WbFlowchartEditor), findsOneWidget);

    // 未修改直接「保存」：应插入默认示例模型并弹出提示，回到白板页。
    await tester.tap(
      find.byKey(const ValueKey<String>('element-editor-save')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WbFlowchartEditor), findsNothing);
    expect(find.textContaining('已插入'), findsOneWidget);
  });

  testWidgets('工具栏风格二选一：默认圆盘，切到顶部后显示面板并禁用长按弹盘（问题 5）',
      (WidgetTester tester) async {
    final WbThemeState theme = await _pumpEditor(tester);

    // 默认（radial）：圆盘可见，顶部面板隐藏。
    expect(find.byType(RadialToolbar), findsOneWidget);
    expect(find.byKey(const Key('wb-canvas-more')), findsNothing);

    theme.applyAppearance(
      theme.appearance.copyWith(
        toolbarStyle: WbAppearancePrefs.toolbarStyleTop,
      ),
    );
    await tester.pumpAndSettle();

    // 顶部风格：面板可见（含「更多」），圆盘隐藏。
    expect(find.byType(RadialToolbar), findsNothing);
    expect(find.byKey(const Key('wb-canvas-more')), findsOneWidget);

    // 顶部风格下长按空白画布不再弹出临时圆盘。
    final TestGesture gesture =
        await tester.startGesture(const Offset(760, 500));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(RadialToolbar), findsNothing);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('协同 UI：默认本地入口（点击弹加入对话框）；参与者面板开 / 关（T1.7）',
      (WidgetTester tester) async {
    await _pumpEditor(tester);

    // 交互改造：白板默认本地，演示模式（无引擎 → 离线）AppBar 显示
    // 「互动白板」入口按钮，而非常驻状态 chip。
    expect(find.byKey(const Key('wb-collab-entry')), findsOneWidget);
    expect(find.text('互动白板'), findsOneWidget);
    expect(find.byKey(const Key('wb-sync-status-chip')), findsNothing);

    // 点击入口：弹出加入对话框（房间号输入 + 服务器地址提示）。
    await tester.tap(find.byKey(const Key('wb-collab-entry')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wb-collab-join-dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('服务器地址：'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('wb-collab-join-cancel')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wb-collab-join-dialog')),
      findsNothing,
    );

    // 参与者入口：打开 endDrawer 面板（无参与者 → 空态）。
    await tester.tap(find.byKey(const Key('wb-participants-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-participants-panel')), findsOneWidget);
    expect(find.text('暂无其他参与者'), findsOneWidget);

    // 「关闭」按钮收起面板。
    await tester.tap(find.descendant(
      of: find.byKey(const Key('wb-participants-panel')),
      matching: find.byTooltip('关闭'),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wb-participants-panel')), findsNothing);
  });
}
