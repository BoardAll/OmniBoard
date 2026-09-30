/// 主窗口关闭拦截（X / Alt+F4）与列表页「退出应用」按钮：无脏直接销毁；
/// 有脏弹三选（保存 / 不保存 / 取消）后决定销毁或留在应用。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/app.dart';
import 'package:whiteboard_desktop/services/board_file_service.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/local_store.dart';
import 'package:whiteboard_desktop/services/settings_store.dart';
import 'package:whiteboard_desktop/services/shortcut_service.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/state/board_state.dart';
import 'package:whiteboard_desktop/state/page_state.dart';
import 'package:whiteboard_desktop/state/theme_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';

/// 演示模式 FFI 服务（候选路径必然失败，保证测试确定性）。
WbFfiService _demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

void main() {
  late Directory tempDir;
  late WbBoardFileService fileService;
  late WbCanvasController canvas;
  late WbThemeState theme;
  late WbCollabService sync;
  late int destroyed;

  String savedPath() => '${tempDir.path}${Platform.pathSeparator}saved.wbd';

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('wb_close_test_');
    destroyed = 0;

    final WbSettingsStore settings = WbSettingsStore(
      localStore: WbLocalStore(baseDirOverride: tempDir.path),
    );
    fileService = WbBoardFileService(
      settings: settings,
      openFilePicker: () async => null,
      saveFilePicker: ({String suggestedPath = ''}) async => savedPath(),
    );

    // 测试侧三源：绑定到应用级文件服务（应用自身不会重复绑定）。
    final WbFfiService ffi = _demoFfi();
    final WbBoardState boardState = WbBoardState(ffi: ffi);
    final WbPageState pageState = WbPageState(ffi: ffi);
    canvas = WbCanvasController();
    boardState.open('board-1', name: '关窗测试');
    pageState.attach(boardState.board!);
    canvas.setPage(pageState.currentPageId);
    fileService.bindBoard(board: boardState, pages: pageState, canvas: canvas);

    theme = WbThemeState();
    sync = WbCollabService();
  });

  tearDown(() {
    fileService.dispose();
    canvas.dispose();
    theme.dispose();
    sync.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(WhiteboardApp(
      ffiService: _demoFfi(),
      themeState: theme,
      collabService: sync,
      shortcutService: WbShortcutService(),
      boardFileService: fileService,
      windowDestroyer: () async {
        destroyed++;
      },
    ));
    await tester.pumpAndSettle();
  }

  dynamic stateOf(WidgetTester tester) =>
      tester.state(find.byType(WhiteboardApp));

  void makeDirty() {
    canvas.insertElement(type: WbElementKind.note, size: const Size(100, 60));
    expect(fileService.hasUnsavedChanges, isTrue);
  }

  testWidgets('无脏改动：直接销毁窗口', (WidgetTester tester) async {
    await pumpApp(tester);
    final dynamic state = stateOf(tester);
    final Future<void> closing = state.handleWindowClose() as Future<void>;
    await closing;
    expect(destroyed, 1);
  });

  testWidgets('有脏改动：取消 → 留在应用且保持脏', (WidgetTester tester) async {
    await pumpApp(tester);
    makeDirty();

    final dynamic state = stateOf(tester);
    final Future<void> closing = state.handleWindowClose() as Future<void>;
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('wb-unsaved-dialog')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('wb-unsaved-cancel')));
    await tester.pumpAndSettle();
    await closing;

    expect(destroyed, 0);
    expect(fileService.hasUnsavedChanges, isTrue);
  });

  testWidgets('有脏改动：不保存 → 销毁（不落盘）', (WidgetTester tester) async {
    await pumpApp(tester);
    makeDirty();

    final dynamic state = stateOf(tester);
    final Future<void> closing = state.handleWindowClose() as Future<void>;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('wb-unsaved-discard')));
    await tester.pumpAndSettle();
    await closing;

    expect(destroyed, 1);
    expect(File(savedPath()).existsSync(), isFalse);
  });

  testWidgets('有脏改动：保存 → 写盘清脏后销毁', (WidgetTester tester) async {
    await pumpApp(tester);
    makeDirty();

    final dynamic state = stateOf(tester);
    final Future<void> closing = state.handleWindowClose() as Future<void>;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('wb-unsaved-save')));
    await tester.pumpAndSettle();
    await closing;

    expect(destroyed, 1);
    expect(fileService.hasUnsavedChanges, isFalse);
    expect(File(savedPath()).existsSync(), isTrue);
  });

  testWidgets('onWindowClose 事件路径：无脏直接销毁', (WidgetTester tester) async {
    await pumpApp(tester);
    final dynamic state = stateOf(tester);
    state.onWindowClose();
    await tester.pumpAndSettle();
    expect(destroyed, 1);
  });

  testWidgets('退出按钮：无脏直接销毁', (WidgetTester tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('退出应用'));
    await tester.pumpAndSettle();
    expect(destroyed, 1);
  });

  testWidgets('退出按钮：有脏取消后可重试，不保存销毁', (WidgetTester tester) async {
    await pumpApp(tester);
    makeDirty();

    // 取消：留在应用且保持脏，可再次请求。
    await tester.tap(find.byTooltip('退出应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('wb-unsaved-cancel')));
    await tester.pumpAndSettle();
    expect(destroyed, 0);
    expect(fileService.hasUnsavedChanges, isTrue);

    // 不保存：销毁（不落盘）。
    await tester.tap(find.byTooltip('退出应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('wb-unsaved-discard')));
    await tester.pumpAndSettle();
    expect(destroyed, 1);
    expect(File(savedPath()).existsSync(), isFalse);
  });

  testWidgets('防重入：销毁决定后再次关闭不再弹窗', (WidgetTester tester) async {
    await pumpApp(tester);
    makeDirty();

    final dynamic state = stateOf(tester);
    final Future<void> closing = state.handleWindowClose() as Future<void>;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('wb-unsaved-discard')));
    await tester.pumpAndSettle();
    await closing;
    expect(destroyed, 1);

    // 再次触发（close() 会重新派发 onWindowClose）：直接忽略。
    final Future<void> again = state.handleWindowClose() as Future<void>;
    await tester.pumpAndSettle();
    await again;
    expect(destroyed, 1);
    expect(
      find.byKey(const ValueKey<String>('wb-unsaved-dialog')),
      findsNothing,
    );
  });
}
