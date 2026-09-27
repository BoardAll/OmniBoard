/// 本地文件 UI 接线：编辑页保存按钮 / Ctrl+S / 返回列表三选 /
/// 列表页最近文件打开（注入假 picker，避免平台对话框）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/app.dart';
import 'package:whiteboard_desktop/services/board_file_codec.dart';
import 'package:whiteboard_desktop/services/board_file_service.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/local_store.dart';
import 'package:whiteboard_desktop/services/settings_store.dart';
import 'package:whiteboard_desktop/services/shortcut_service.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/state/theme_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';

/// 演示模式 FFI 服务（候选路径必然失败，保证测试确定性）。
WbFfiService _demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

void main() {
  late Directory tempDir;
  late WbSettingsStore settings;
  late WbBoardFileService files;
  late int savePickerCalls;
  late String savePickerPath;
  String? openPickerPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('wb_file_ui_');
    settings = WbSettingsStore(
      localStore: WbLocalStore(baseDirOverride: tempDir.path),
    );
    savePickerCalls = 0;
    savePickerPath = '${tempDir.path}${Platform.pathSeparator}board.wbd';
    openPickerPath = null;
    files = WbBoardFileService(
      settings: settings,
      openFilePicker: () async => openPickerPath,
      saveFilePicker: ({String suggestedPath = ''}) async {
        savePickerCalls++;
        return savePickerPath;
      },
    );
  });

  tearDown(() {
    files.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final WbThemeState theme = WbThemeState();
    final WbSyncService sync = WbSyncService();
    addTearDown(() {
      theme.dispose();
      sync.dispose();
    });

    await tester.pumpWidget(WhiteboardApp(
      ffiService: _demoFfi(),
      themeState: theme,
      syncService: sync,
      shortcutService: WbShortcutService(),
      boardFileService: files,
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openEditor(WidgetTester tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('新建白板'));
    await tester.pumpAndSettle();
  }

  /// 快速创建流程图并保存到画布（产生真实编辑 → 置脏）。
  Future<void> insertQuickFlowchart(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-quick-create-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('wb-ctx-quick-create-flowchart')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('element-editor-save')),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pressCtrlS(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// 等待保存提示 SnackBar（2s）消失，避免遮挡底部快速创建按钮。
  Future<void> flushSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  testWidgets('保存按钮：首存走另存为并落盘、清脏', (WidgetTester tester) async {
    await openEditor(tester);
    expect(files.isBound, isTrue);
    expect(files.hasUnsavedChanges, isFalse);

    await tester.tap(find.byTooltip('保存白板（Ctrl+S）'));
    await tester.pumpAndSettle();

    expect(savePickerCalls, 1);
    expect(files.filePath, savePickerPath);
    expect(files.hasUnsavedChanges, isFalse);
    expect(File(savePickerPath).existsSync(), isTrue);
    expect(find.textContaining('已保存'), findsOneWidget);
  });

  testWidgets('编辑置脏：标题脏标记与 Ctrl+S 直存同路径', (WidgetTester tester) async {
    await openEditor(tester);
    await tester.tap(find.byTooltip('保存白板（Ctrl+S）'));
    await tester.pumpAndSettle();
    expect(find.text('演示白板 •'), findsNothing);

    await flushSnackBar(tester);
    await insertQuickFlowchart(tester);
    expect(files.hasUnsavedChanges, isTrue);
    expect(find.text('演示白板 •'), findsOneWidget);

    await pressCtrlS(tester);
    expect(savePickerCalls, 1); // 已有路径：不再弹另存为
    expect(files.hasUnsavedChanges, isFalse);
    expect(find.text('演示白板 •'), findsNothing);

    final WbBoardData data = WbBoardFileCodec.decode(
      File(savePickerPath).readAsStringSync(),
    );
    expect(data.pages.single.elements.length, 1);
    expect(data.pages.single.elements.single.type, WbElementKind.flowchart);
  });

  testWidgets('返回列表：取消留在编辑页；不保存直接回列表',
      (WidgetTester tester) async {
    await openEditor(tester);
    await insertQuickFlowchart(tester);
    expect(files.hasUnsavedChanges, isTrue);

    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wb-unsaved-dialog')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('wb-unsaved-cancel')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回列表'), findsOneWidget); // 仍在编辑页
    expect(files.hasUnsavedChanges, isTrue);

    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('wb-unsaved-discard')));
    await tester.pumpAndSettle();

    expect(find.text('新建白板'), findsOneWidget); // 回到列表页
    expect(files.isBound, isFalse);
    expect(files.hasUnsavedChanges, isFalse);
  });

  testWidgets('返回列表：保存成功后回列表并写入最近列表',
      (WidgetTester tester) async {
    await openEditor(tester);
    await insertQuickFlowchart(tester);

    await tester.tap(find.byTooltip('返回列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('wb-unsaved-save')));
    await tester.pumpAndSettle();

    expect(find.text('新建白板'), findsOneWidget);
    expect(File(savePickerPath).existsSync(), isTrue);
    expect(settings.recentBoards.single.path, savePickerPath);
  });

  testWidgets('列表页：最近文件卡片打开并还原内容', (WidgetTester tester) async {
    // 预写一个白板文件并写入最近列表（模拟上次会话保存过）。
    final String path =
        '${tempDir.path}${Platform.pathSeparator}roundtrip.wbd';
    File(path).writeAsStringSync(WbBoardFileCodec.encode(const WbBoardData(
      boardId: 'board-x',
      boardName: '打开测试',
      currentPageId: 'p1',
      pages: <WbBoardPageData>[
        WbBoardPageData(
          id: 'p1',
          elements: <WbCanvasElement>[
            WbCanvasElement(
              id: 'e1',
              type: WbElementKind.note,
              x: 0,
              y: 0,
              width: 120,
              height: 80,
              text: '来自文件',
            ),
          ],
        ),
      ],
    )));
    settings.rememberBoard(path: path, name: '打开测试');

    await pumpApp(tester);
    expect(find.text('本地文件'), findsOneWidget);
    expect(find.text('打开测试'), findsOneWidget);

    await tester.tap(find.text('打开测试'));
    await tester.pumpAndSettle();

    expect(files.isBound, isTrue);
    expect(files.filePath, path);
    expect(files.hasUnsavedChanges, isFalse);
    expect(find.textContaining('已打开'), findsOneWidget);
  });

  testWidgets('列表页：打开按钮取消选择无副作用（不崩溃）',
      (WidgetTester tester) async {
    await pumpApp(tester);
    expect(find.text('我的白板'), findsOneWidget);

    openPickerPath = null;
    await tester.tap(find.byTooltip('打开本地白板'));
    await tester.pumpAndSettle();

    expect(find.text('我的白板'), findsOneWidget); // 仍在列表页
    expect(files.filePath, '');
  });
}
