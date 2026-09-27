// §7.2 FFI 集成（真实 wb_core.dll）：元素 CRUD / 命令总线 / 工具调用 / 错误语义。
//
// 封装层回归：Wave4 总集成已修复以下两处 packages/core_dart 封装偏差，
// 用例固化为回归保护：
// ① WbBoardService.undo/redo 改发 `command.undo`/`command.redo`（command 域）；
// ② WbElementService.batch 改发顶层数组（`wb_element_batch` 契约形态）。
// 渲染域（render*）封装偏差仍为已知记录项，见 ffi_render_test.dart。
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core.dart';

import 'support/ffi_support.dart';

void main() {
  final String? dllPath = resolveWbCoreDll();
  final String? skipReason = ffiIntegrationSkipReason();

  late WbCoreFfi ffi;

  setUpAll(() {
    if (dllPath != null) {
      ffi = loadRealCore(dllPath);
    }
  });

  test('元素 CRUD：创建 → 列表包含 → 更新 → 删除', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 命令 CRUD');
    final WbElementService elements = WbElementService(ffi);
    const String elementId = 'ffi-cmd-crud-1';

    final WbElement created = elements.create(probe.pageId, <String, dynamic>{
      'id': elementId,
      'type': 'sticky',
      'position': <String, dynamic>{'x': 12, 'y': 34},
      'size': <String, dynamic>{'width': 180, 'height': 120},
      'text': '命令总线用例',
    });
    expect(created.id, elementId);
    expect(created.type, 'sticky');
    expect(created.x, 12);
    expect(created.y, 34);
    expect(created.width, 180);

    final List<WbElement> listed = elements.list(probe.pageId);
    expect(listed.map((WbElement e) => e.id), contains(elementId));

    final WbElement updated =
        elements.update(elementId, <String, dynamic>{'text': '已更新'});
    expect(updated.id, elementId);
    expect(updated['text'], '已更新');

    final Map<String, dynamic> deleted = elements.delete(elementId);
    expect(deleted['elementId'], elementId);

    final List<WbElement> after = elements.list(probe.pageId);
    expect(after.map((WbElement e) => e.id), isNot(contains(elementId)));
  }, skip: skipReason);

  test('命令总线：element.create / command.history / command.undo / command.redo',
      () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 命令撤销');
    final WbBoardService boards = WbBoardService(ffi);
    final WbElementService elements = WbElementService(ffi);
    const String elementId = 'ffi-cmd-undo-1';

    final Map<String, dynamic> created = boards.executeCommand(
      probe.handle,
      <String, dynamic>{
        'type': 'element.create',
        'params': <String, dynamic>{
          'pageId': probe.pageId,
          'element': <String, dynamic>{
            'id': elementId,
            'type': 'rect',
            'position': <String, dynamic>{'x': 0, 'y': 0},
            'size': <String, dynamic>{'width': 40, 'height': 30},
          },
        },
      },
    );
    expect(created['elementId'], elementId);

    final Map<String, dynamic> history = boards.executeCommand(
      probe.handle,
      <String, dynamic>{'type': 'command.history', 'params': <String, dynamic>{}},
    );
    expect((history['undoCount'] as num).toInt(), greaterThanOrEqualTo(1));
    expect((history['redoCount'] as num).toInt(), greaterThanOrEqualTo(0));

    final Map<String, dynamic> undone = boards.executeCommand(
      probe.handle,
      <String, dynamic>{'type': 'command.undo', 'params': <String, dynamic>{}},
    );
    expect((undone['undone'] as num).toInt(), 1);
    expect(
      elements.list(probe.pageId).map((WbElement e) => e.id),
      isNot(contains(elementId)),
    );

    final Map<String, dynamic> redone = boards.executeCommand(
      probe.handle,
      <String, dynamic>{'type': 'command.redo', 'params': <String, dynamic>{}},
    );
    expect((redone['redone'] as num).toInt(), 1);
    expect(
      elements.list(probe.pageId).map((WbElement e) => e.id),
      contains(elementId),
    );
  }, skip: skipReason);

  test('工具调用：board.get / page.list / theme.list', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 工具调用');
    final WbBoardService boards = WbBoardService(ffi);

    final Map<String, dynamic> boardGet = boards.executeTool(
      'board.get',
      <String, dynamic>{'handle': probe.handle},
    );
    expect(WbJsonCodec.unwrap(boardGet, 'board')['id'], probe.boardId);

    final Map<String, dynamic> pageList = boards.executeTool(
      'page.list',
      <String, dynamic>{'boardId': probe.boardId},
    );
    expect((pageList['count'] as num).toInt(), greaterThanOrEqualTo(1));
    final List<Map<String, dynamic>> pages =
        WbJsonCodec.extractList(pageList['pages']);
    expect(pages.map((Map<String, dynamic> p) => p['id']), contains(probe.pageId));

    final Map<String, dynamic> themes = boards.executeTool('theme.list');
    expect((themes['count'] as num).toInt(), 9);
    final List<Map<String, dynamic>> themeItems =
        WbJsonCodec.extractList(themes['themes']);
    expect(
      themeItems.map((Map<String, dynamic> t) => t['id']),
      contains('clean-professional'),
    );
  }, skip: skipReason);

  test('错误语义：无效 JSON / 未知域 / 缺字段返回错误信封而非崩溃', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 错误语义');

    final WbResponse badJson = WbResponse.parse(
      ffi.callHandle1(ffi.bindings.wbExecuteCommand, probe.handle, 'not-json'),
    );
    expect(badJson.ok, isFalse);
    expect(badJson.code, 'InvalidArgument');
    expect(badJson.message, 'command must be an object');

    final WbResponse missingType = WbResponse.parse(
      ffi.call2(ffi.bindings.wbElementCreate, probe.pageId, '{}'),
    );
    expect(missingType.ok, isFalse);
    expect(missingType.code, 'InvalidArgument');
    expect(missingType.message, 'element.type is required');

    final WbResponse unknownDomain = WbResponse.parse(
      ffi.callHandle1(
        ffi.bindings.wbExecuteCommand,
        probe.handle,
        '{"type":"no.such.command","params":{}}',
      ),
    );
    expect(unknownDomain.ok, isFalse);
    expect(unknownDomain.code, 'NotFound');
    expect(unknownDomain.message, startsWith('unknown domain'));

    expect(() => badJson.requireResult(), throwsA(isA<WbCoreException>()));
    expect(() => missingType.requireResult(), throwsA(isA<WbCoreException>()));
  }, skip: skipReason);

  test('回归：服务 undo/redo 走 command 域（Wave4 已修复）', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 撤销回归');
    final WbBoardService boards = WbBoardService(ffi);
    final WbElementService elements = WbElementService(ffi);
    boards.executeCommand(probe.handle, <String, dynamic>{
      'type': 'element.create',
      'params': <String, dynamic>{
        'pageId': probe.pageId,
        'element': <String, dynamic>{
          'id': 'ffi-cmd-regression-undo',
          'type': 'rect',
          'position': <String, dynamic>{'x': 0, 'y': 0},
          'size': <String, dynamic>{'width': 10, 'height': 10},
        },
      },
    });
    expect(
      elements.list(probe.pageId).map((WbElement e) => e.id),
      contains('ffi-cmd-regression-undo'),
    );

    final Map<String, dynamic> undone = boards.undo(probe.handle);
    expect((undone['undone'] as num).toInt(), 1);
    expect(
      elements.list(probe.pageId).map((WbElement e) => e.id),
      isNot(contains('ffi-cmd-regression-undo')),
    );

    final Map<String, dynamic> redone = boards.redo(probe.handle);
    expect((redone['redone'] as num).toInt(), 1);
    expect(
      elements.list(probe.pageId).map((WbElement e) => e.id),
      contains('ffi-cmd-regression-undo'),
    );
  }, skip: skipReason);

  test('回归：batch 封装发送顶层数组（Wave4 已修复）', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 批处理回归');
    final WbElementService elements = WbElementService(ffi);
    elements.create(probe.pageId, <String, dynamic>{
      'id': 'ffi-cmd-batch-1',
      'type': 'rect',
      'position': <String, dynamic>{'x': 0, 'y': 0},
      'size': <String, dynamic>{'width': 10, 'height': 10},
    });

    final Map<String, dynamic> result =
        elements.batch(probe.pageId, <Map<String, dynamic>>[
      <String, dynamic>{'op': 'delete', 'elementId': 'ffi-cmd-batch-1'},
    ]);
    expect((result['executed'] as num).toInt(), 1);
    expect(
      elements.list(probe.pageId).map((WbElement e) => e.id),
      isNot(contains('ffi-cmd-batch-1')),
    );
  }, skip: skipReason);
}
