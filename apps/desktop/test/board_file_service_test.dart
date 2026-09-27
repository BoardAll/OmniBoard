/// 白板文件服务：绑定 / 脏标记（documentRevision 比较）/ 另存为 / 保存 /
/// 打开 / 最近列表 / 路径工具；全程注入假 picker 与临时目录。
library;

import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/services/board_file_codec.dart';
import 'package:whiteboard_desktop/services/board_file_service.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/local_store.dart';
import 'package:whiteboard_desktop/services/settings_store.dart';
import 'package:whiteboard_desktop/state/board_state.dart';
import 'package:whiteboard_desktop/state/page_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';

/// 演示模式 FFI 服务（候选路径必然失败，保证测试确定性）。
WbFfiService _demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late WbSettingsStore settings;
  late WbBoardFileService service;
  late WbBoardState boardState;
  late WbPageState pageState;
  WbCanvasController? canvas;
  int savePickerCalls = 0;
  String? savePickerResult;
  String? openPickerResult;

  String p(String name) => '${tempDir.path}${Platform.pathSeparator}$name';

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('wb_board_svc_');
    settings = WbSettingsStore(
      localStore: WbLocalStore(
        baseDirOverride: '${tempDir.path}${Platform.pathSeparator}cfg',
      ),
    );
    savePickerCalls = 0;
    savePickerResult = null;
    openPickerResult = null;
    canvas = null;
    service = WbBoardFileService(
      settings: settings,
      openFilePicker: () async => openPickerResult,
      saveFilePicker: ({String suggestedPath = ''}) async {
        savePickerCalls++;
        return savePickerResult;
      },
    );
  });

  tearDown(() {
    service.dispose();
    canvas?.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 新建一套三源并绑定文件服务（干净基线）。
  void bind() {
    final WbFfiService ffi = _demoFfi();
    boardState = WbBoardState(ffi: ffi);
    pageState = WbPageState(ffi: ffi);
    final WbCanvasController liveCanvas = WbCanvasController();
    canvas = liveCanvas;
    boardState.open('board-1', name: '测试白板');
    pageState.attach(boardState.board!);
    liveCanvas.setPage(pageState.currentPageId);
    service.bindBoard(board: boardState, pages: pageState, canvas: liveCanvas);
  }

  WbCanvasElement insertNote() => canvas!.insertElement(
        type: WbElementKind.note,
        size: const Size(120, 80),
      );

  test('绑定即干净基线：编辑置脏', () {
    bind();
    expect(service.isBound, isTrue);
    expect(service.hasUnsavedChanges, isFalse);
    expect(service.filePath, '');
    expect(canvas!.documentRevision, 0);

    insertNote();
    expect(canvas!.documentRevision, greaterThan(0));
    expect(service.hasUnsavedChanges, isTrue);
  });

  test('页面状态通知置脏（非画布变更同样计入）', () {
    bind();
    pageState.setElementCount(pageState.currentPageId, 3);
    expect(service.hasUnsavedChanges, isTrue);
  });

  test('保存：首存另存为（补后缀）→ 写盘 → 清脏 → recent 写回', () async {
    bind();
    insertNote();

    savePickerResult = p('dir${Platform.pathSeparator}测试板');
    final WbSaveOutcome outcome = await service.save();
    expect(outcome.status, WbSaveStatus.saved);
    expect(savePickerCalls, 1);
    expect(outcome.message, p('dir${Platform.pathSeparator}测试板.wbd'));
    expect(service.filePath, p('dir${Platform.pathSeparator}测试板.wbd'));
    expect(service.fileDisplayName, '测试板.wbd');
    expect(service.hasUnsavedChanges, isFalse);
    expect(File(service.filePath).existsSync(), isTrue);

    final WbBoardData data = WbBoardFileCodec.decode(
      File(service.filePath).readAsStringSync(),
    );
    expect(data.boardId, 'board-1');
    expect(data.boardName, '测试白板');
    expect(data.currentPageId, pageState.currentPageId);
    expect(data.pages.single.elements.single.type, WbElementKind.note);

    // recent 写回并持久化到设置存储。
    expect(service.recentBoards.single.path, service.filePath);
    expect(settings.recentBoards.single.path, service.filePath);
  });

  test('再次保存：已有路径不弹框、内容增量落盘', () async {
    bind();
    insertNote();
    savePickerResult = p('board.wbd');
    await service.save();
    expect(savePickerCalls, 1);

    insertNote();
    expect(service.hasUnsavedChanges, isTrue);
    final WbSaveOutcome second = await service.save();
    expect(second.status, WbSaveStatus.saved);
    expect(savePickerCalls, 1); // 不再弹另存为
    final WbBoardData updated = WbBoardFileCodec.decode(
      File(service.filePath).readAsStringSync(),
    );
    expect(updated.pages.single.elements.length, 2);
    expect(service.hasUnsavedChanges, isFalse);
  });

  test('取消另存为：保持脏、路径不变', () async {
    bind();
    insertNote();
    savePickerResult = null;
    final WbSaveOutcome outcome = await service.save(saveAs: true);
    expect(outcome.status, WbSaveStatus.cancelled);
    expect(service.hasUnsavedChanges, isTrue);
    expect(service.filePath, '');
  });

  test('保存失败：目标不可写返回 failed 且保持脏', () async {
    bind();
    insertNote();
    final String blocked = p('blocked.wbd');
    Directory(blocked).createSync(); // 目录占位使写文件失败
    savePickerResult = blocked;
    final WbSaveOutcome outcome = await service.save();
    expect(outcome.status, WbSaveStatus.failed);
    expect(outcome.message, contains('保存失败'));
    expect(service.hasUnsavedChanges, isTrue);
  });

  test('未绑定：保存 / 打开返回失败提示', () async {
    final WbSaveOutcome save = await service.save();
    expect(save.status, WbSaveStatus.failed);
    expect(save.message, contains('未就绪'));
    final WbOpenOutcome open = await service.openPath(p('x.wbd'));
    expect(open.status, WbOpenStatus.failed);
    expect(open.message, contains('未就绪'));
  });

  test('打开：openPath 还原三源、清脏、更新 filePath 与 recent', () async {
    // 先经保存链路写出一份真实文件。
    bind();
    insertNote();
    savePickerResult = p('source.wbd');
    await service.save();
    final String sourcePath = service.filePath;

    // 全新三源（模拟重启后打开）。
    bind();
    expect(service.hasUnsavedChanges, isFalse);
    final WbOpenOutcome outcome = await service.openPath(sourcePath);
    expect(outcome.status, WbOpenStatus.opened);
    expect(service.filePath, sourcePath);
    expect(service.hasUnsavedChanges, isFalse);
    expect(boardState.board!.name, '测试白板');
    expect(pageState.pages.length, 1);
    expect(canvas!.pageId, pageState.currentPageId);
    expect(
      canvas!.document.snapshot(pageState.currentPageId).single.type,
      WbElementKind.note,
    );
    expect(settings.recentBoards.first.path, sourcePath);

    // openWithDialog 成功路径（picker 返回同路径）。
    openPickerResult = sourcePath;
    final WbOpenOutcome viaDialog = await service.openWithDialog();
    expect(viaDialog.status, WbOpenStatus.opened);
  });

  test('打开失败：文件不存在 / 内容损坏 / 对话框取消', () async {
    bind();
    final WbOpenOutcome missing = await service.openPath(p('missing.wbd'));
    expect(missing.status, WbOpenStatus.failed);
    expect(missing.message, contains('文件不存在'));

    File(p('bad.wbd')).writeAsStringSync('oops');
    final WbOpenOutcome bad = await service.openPath(p('bad.wbd'));
    expect(bad.status, WbOpenStatus.failed);
    expect(bad.message, contains('无法打开'));

    openPickerResult = null;
    final WbOpenOutcome cancelled = await service.openWithDialog();
    expect(cancelled.status, WbOpenStatus.cancelled);
    expect(service.hasUnsavedChanges, isFalse);
  });

  test('unbind：解绑清态且不再响应后续变更', () {
    bind();
    insertNote();
    expect(service.hasUnsavedChanges, isTrue);

    service.unbind();
    expect(service.isBound, isFalse);
    expect(service.hasUnsavedChanges, isFalse);
    expect(service.filePath, '');

    insertNote(); // 解绑后画布变更不再置脏
    expect(service.hasUnsavedChanges, isFalse);
  });

  test('removeRecentBoard：从最近列表移除', () async {
    bind();
    insertNote();
    savePickerResult = p('r.wbd');
    await service.save();
    expect(service.recentBoards, isNotEmpty);

    service.removeRecentBoard(p('r.wbd'));
    expect(service.recentBoards, isEmpty);
    expect(settings.recentBoards, isEmpty);
  });

  test('路径工具：ensureWbdExtension / suggestedSavePath', () {
    expect(WbBoardFileService.ensureWbdExtension(r'C:\a.wbd'), r'C:\a.wbd');
    expect(WbBoardFileService.ensureWbdExtension(r'C:\a'), r'C:\a.wbd');
    expect(WbBoardFileService.ensureWbdExtension('a.WBD'), 'a.WBD');

    expect(
      WbBoardFileService.suggestedSavePath(''),
      endsWith('未命名白板.wbd'),
    );
    expect(
      WbBoardFileService.suggestedSavePath('计划:第一版'),
      contains('计划_第一版.wbd'),
    );
  });
}
