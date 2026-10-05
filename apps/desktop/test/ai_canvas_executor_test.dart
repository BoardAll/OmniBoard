/// AI 工具执行器与画布批量编辑测试（AI 生成内容落画布链路回归）。
///
/// 覆盖：
/// - [WbCanvasController] 批量插入 / 批量删除 / 整页快照恢复（同一撤销单元）；
/// - [WbAiCanvasExecutor]：element_create / update / move / delete 真实落画布、
///   参数别名与容错解析、执行器 undo 整体恢复；
/// - [WbAiState]：绑定执行器后 approveToolCall 走真实执行、undoToolCall 回滚，
///   未绑定执行器时保持模拟执行兜底，执行器异常降级为 error 状态。
///
/// 说明：不依赖真实网络与 DLL —— AI 走假提供商（`ai_service` 装配面），
/// FFI 走演示模式（候选 DLL 路径必然失败）。
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_ai/ai_client.dart';
import 'package:whiteboard_desktop/services/ai_canvas_executor.dart';
import 'package:whiteboard_desktop/services/ai_service.dart';
import 'package:whiteboard_desktop/services/ai_tools.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/state/ai_state.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';

// ---- 测试基建 -------------------------------------------------------------

/// 构造演示模式 FFI 服务（候选路径必然失败，保证测试确定性）。
WbFfiService _demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

/// 构造带 800x600 视口的画布控制器（默认页 `''`，视口中心世界坐标 400,300）。
WbCanvasController _canvas({WbSelectionState? selection}) {
  return WbCanvasController(selection: selection)
    ..setViewportSize(const Size(800, 600));
}

/// 预置两个便签元素（a：0,0,100x100；b：200,0,100x100）。
void _seedTwoNotes(WbCanvasController c) {
  c.document.upsert(
    '',
    const WbCanvasElement(
      id: 'a',
      type: WbElementKind.note,
      x: 0,
      y: 0,
      width: 100,
      height: 100,
      zIndex: 1,
    ),
  );
  c.document.upsert(
    '',
    const WbCanvasElement(
      id: 'b',
      type: WbElementKind.note,
      x: 200,
      y: 0,
      width: 100,
      height: 100,
      zIndex: 2,
    ),
  );
}

/// 构造工具调用（仅执行器消费的字段）。
AiToolCall _call(
  String name,
  Map<String, dynamic> arguments, {
  String id = 'call_1',
}) {
  return AiToolCall(id: id, name: name, arguments: arguments);
}

/// 产出 `element_create`（两条便签，参数字段形态与真实模型一致）的假提供商。
class _CreateToolProvider extends AiProvider {
  @override
  String get id => 'fake-tools';

  @override
  String get defaultModel => 'fake-1';

  @override
  Future<AiChatResponse> chat(AiChatRequest request) async =>
      AiChatResponse(message: AiMessage.assistant(''));

  @override
  Stream<AiStreamEvent> chatStream(AiChatRequest request) async* {
    yield const AiToolCallDelta(
      index: 0,
      id: 'call_1',
      name: 'element_create',
      argumentsDelta: '{"elements":[{"id":"g1","type":"note","label":"痛点",'
          '"position":{"x":10,"y":20},'
          '"size":{"width":120,"height":80}},{"id":"g2","type":"note",'
          '"label":"场景","position":{"x":150,"y":20},'
          '"size":{"width":120,"height":80}}]}',
    );
    yield const AiStreamDone();
  }
}

/// 执行器抛异常的假实现（验证状态层错误兜底）。
class _ThrowingExecutor implements WbAiToolExecutor {
  @override
  Future<Map<String, dynamic>> execute(AiToolCall call) async {
    throw StateError('boom');
  }

  @override
  void undo(AiToolCall call) {}
}

void main() {
  // -------------------------------------------------------------------------
  // 画布：批量插入 / 删除 / 快照恢复
  // -------------------------------------------------------------------------

  group('WbCanvasController 批量编辑', () {
    test('insertElements：批量创建同一撤销单元，undo 一次全部恢复', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = _canvas(selection: sel);
      final List<WbCanvasElement> created = c.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.note,
          text: '痛点',
          position: Offset(10, 20),
          size: Size(120, 80),
          color: 0xFF12AB34,
        ),
        const WbElementSpec(
          type: WbElementKind.note,
          text: '场景',
          position: Offset(150, 20),
          size: Size(120, 80),
        ),
      ]);

      expect(created.length, 2);
      expect(c.elements.length, 2);
      expect(created.first.id, isNot(created.last.id));
      expect(sel.ids, <String>{created.first.id, created.last.id});

      final WbCanvasElement first = c.document.byId('', created.first.id)!;
      expect(first.type, WbElementKind.note);
      expect(first.text, '痛点');
      expect(first.bounds, const Rect.fromLTWH(10, 20, 120, 80));
      expect(first.color, 0xFF12AB34);
      expect(c.document.byId('', created.last.id)!.text, '场景');

      // 一个撤销单元：一次 undo 全部移除。
      c.undo();
      expect(c.elements, isEmpty);
    });

    test('insertElements：未给 position 时按序阶梯错位落视口中心', () {
      final WbCanvasController c = _canvas();
      final List<WbCanvasElement> created = c.insertElements(<WbElementSpec>[
        const WbElementSpec(type: WbElementKind.note, text: '一'),
        const WbElementSpec(type: WbElementKind.note, text: '二'),
      ]);

      // 视口中心 (400,300)、便签默认 180x120；第二条阶梯错位 24。
      expect(created[0].x, 400 - 90);
      expect(created[0].y, 300 - 60);
      expect(created[1].x, 400 - 90 + 24);
      expect(created[1].y, 300 - 60 + 24);
    });

    test('insertElements：drawing 以 points 包围盒定几何并同步平移', () {
      final WbCanvasController c = _canvas();
      final WbCanvasElement e = c.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.drawing,
          points: <Offset>[Offset(0, 0), Offset(50, 30), Offset(100, 60)],
        ),
      ]).single;

      expect(e.x, 350);
      expect(e.y, 270);
      expect(e.width, 100);
      expect(e.height, 60);
      expect(e.points, <Offset>[
        const Offset(350, 270),
        const Offset(400, 300),
        const Offset(450, 330),
      ]);
    });

    test('removeElements：批量删除一个撤销单元，忽略不存在的 id', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = _canvas(selection: sel);
      _seedTwoNotes(c);
      sel.select(<String>['a', 'b']);

      expect(c.removeElements(<String>['a', 'b', 'missing']), 2);
      expect(c.elements, isEmpty);
      expect(sel.ids, isEmpty);

      c.undo();
      expect(c.elements.length, 2);
    });

    test('restoreElements：整页快照恢复入撤销栈并收敛选择', () {
      final WbSelectionState sel = WbSelectionState();
      final WbCanvasController c = _canvas(selection: sel);
      _seedTwoNotes(c);
      final List<WbCanvasElement> snapshot = c.pageSnapshot();

      c.removeElements(<String>['a']);
      sel.select(<String>['a', 'ghost']);
      c.restoreElements(snapshot);

      expect(c.elements.length, 2);
      expect(c.document.byId('', 'a'), isNotNull);
      expect(sel.ids, <String>{'a'}); // ghost 不在快照中，被收敛移除。

      // 恢复本身也是一个撤销单元。
      c.undo();
      expect(c.elements.single.id, 'b');
    });
  });

  // -------------------------------------------------------------------------
  // 执行器：工具落地画布
  // -------------------------------------------------------------------------

  group('WbAiCanvasExecutor 工具落地', () {
    test('element_create：便签批量落地（别名归一 / 颜色解析 / 摘要格式）', () async {
      final WbCanvasController c = _canvas();
      final WbAiCanvasExecutor exec = WbAiCanvasExecutor(canvas: c);

      final Map<String, dynamic> result = await exec.execute(
        _call(WbBoardTools.elementCreate, <String, dynamic>{
          'elements': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'sticky', // 别名 → note
              'label': '痛点', // 别名 → text
              'position': <String, dynamic>{'x': 10, 'y': 20},
              'size': <String, dynamic>{'width': 120, 'height': 80},
              'color': '#FF12AB34',
            },
            <String, dynamic>{
              'id': 'g2', // 模型侧 id 忽略，画布分配真实 id
              'type': 'note',
              'text': '场景',
              'position': <String, dynamic>{'x': 150, 'y': 20},
              'size': <String, dynamic>{'width': 120, 'height': 80},
            },
          ],
        }),
      );

      expect(result['ok'], isTrue);
      expect(result['affected'], 2);
      expect(result['summary'], '已执行 element_create（影响 2 个元素）');
      expect(
        result['ids'],
        <String>[for (final WbCanvasElement e in c.elements) e.id],
      );

      expect(c.elements.length, 2);
      final WbCanvasElement first = c.elements.first;
      expect(first.type, WbElementKind.note);
      expect(first.text, '痛点');
      expect(first.bounds, const Rect.fromLTWH(10, 20, 120, 80));
      expect(first.color, 0xFF12AB34);
      expect(c.elements.last.text, '场景');
    });

    test('element_create：drawing 以 points 包围盒归一并平移落点', () async {
      final WbCanvasController c = _canvas();
      final WbAiCanvasExecutor exec = WbAiCanvasExecutor(canvas: c);

      // 单元素顶层形态（无 elements 数组）。
      final Map<String, dynamic> result = await exec.execute(
        _call(WbBoardTools.elementCreate, <String, dynamic>{
          'type': 'drawing',
          'points': <Map<String, dynamic>>[
            <String, dynamic>{'x': 0, 'y': 0},
            <String, dynamic>{'x': 40, 'y': 20},
            <String, dynamic>{'x': 80, 'y': 0},
          ],
        }),
      );

      expect(result['ok'], isTrue);
      expect(result['affected'], 1);
      final WbCanvasElement e = c.elements.single;
      expect(e.type, WbElementKind.drawing);
      expect(e.x, 360);
      expect(e.y, 288);
      expect(e.width, 80);
      expect(e.height, 24);
      expect(e.points, <Offset>[
        const Offset(360, 288),
        const Offset(400, 308),
        const Offset(440, 288),
      ]);
    });

    test('element_update：patch 应用属性；尺寸/位置变化同步缩放 points', () async {
      final WbCanvasController c = _canvas();
      final WbAiCanvasExecutor exec = WbAiCanvasExecutor(canvas: c);

      final WbCanvasElement created = c.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.drawing,
          points: <Offset>[Offset(0, 0), Offset(100, 50)],
          position: Offset(0, 0),
        ),
      ]).single;
      expect(created.points, <Offset>[
        const Offset(0, 0),
        const Offset(100, 50),
      ]);

      final AiToolCall call = _call(
        WbBoardTools.elementUpdate,
        <String, dynamic>{
          'elementId': created.id,
          'patch': <String, dynamic>{
            'text': '已修正',
            'position': <String, dynamic>{'x': 100, 'y': 100},
            'size': <String, dynamic>{'width': 200, 'height': 100},
            'color': '#FF00FF00',
          },
        },
      );
      final Map<String, dynamic> result = await exec.execute(call);

      expect(result['ok'], isTrue);
      final WbCanvasElement updated = c.document.byId('', created.id)!;
      expect(updated.text, '已修正');
      expect(updated.bounds, const Rect.fromLTWH(100, 100, 200, 100));
      expect(updated.color, 0xFF00FF00);
      expect(updated.points, <Offset>[
        const Offset(100, 100),
        const Offset(300, 200),
      ]);

      // 执行器 undo：整页快照恢复（含 points 与文本）。
      exec.undo(call);
      final WbCanvasElement restored = c.document.byId('', created.id)!;
      expect(restored.text, isEmpty);
      expect(restored.bounds, const Rect.fromLTWH(0, 0, 100, 50));
      expect(restored.points, <Offset>[
        const Offset(0, 0),
        const Offset(100, 50),
      ]);
    });

    test('element_move：dx/dy 增量平移笔迹 points 并支持执行器 undo', () async {
      final WbCanvasController c = _canvas();
      final WbAiCanvasExecutor exec = WbAiCanvasExecutor(canvas: c);

      final WbCanvasElement created = c.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.connector,
          points: <Offset>[Offset(10, 20), Offset(110, 60)],
          position: Offset(0, 0),
        ),
      ]).single;
      expect(created.points, <Offset>[
        const Offset(0, 0),
        const Offset(100, 40),
      ]);

      final AiToolCall call = _call(
        WbBoardTools.elementMove,
        <String, dynamic>{'elementId': created.id, 'dx': 30, 'dy': -10},
      );
      final Map<String, dynamic> result = await exec.execute(call);

      expect(result['ok'], isTrue);
      final WbCanvasElement moved = c.document.byId('', created.id)!;
      expect(moved.bounds, const Rect.fromLTWH(30, -10, 100, 40));
      expect(moved.points, <Offset>[
        const Offset(30, -10),
        const Offset(130, 30),
      ]);

      exec.undo(call);
      expect(c.document.byId('', created.id)!.points, <Offset>[
        const Offset(0, 0),
        const Offset(100, 40),
      ]);
    });

    test('element_delete：批量删除返回实际数量；elementId 单值兼容；undo 恢复', () async {
      final WbCanvasController c = _canvas();
      final WbAiCanvasExecutor exec = WbAiCanvasExecutor(canvas: c);
      _seedTwoNotes(c);

      final AiToolCall batch = _call(
        WbBoardTools.elementDelete,
        <String, dynamic>{
          'ids': <String>['a', 'b', 'missing'],
        },
      );
      final Map<String, dynamic> result = await exec.execute(batch);
      expect(result['ok'], isTrue);
      expect(result['affected'], 2);
      expect(c.elements, isEmpty);

      exec.undo(batch);
      expect(c.elements.length, 2);

      final Map<String, dynamic> single = await exec.execute(
        _call(
          WbBoardTools.elementDelete,
          <String, dynamic>{'elementId': 'a'},
          id: 'call_2',
        ),
      );
      expect(single['affected'], 1);
      expect(c.elements.single.id, 'b');
    });

    test('执行器容错：未知工具 / 缺参数返回 error 且不修改画布', () async {
      final WbCanvasController c = _canvas();
      final WbAiCanvasExecutor exec = WbAiCanvasExecutor(canvas: c);

      final Map<String, dynamic> unknown = await exec.execute(
        _call('element_unknown', const <String, dynamic>{}),
      );
      expect(unknown['ok'], isFalse);
      expect('${unknown['error']}', contains('不支持的工具'));

      final Map<String, dynamic> empty = await exec.execute(
        _call(WbBoardTools.elementCreate, const <String, dynamic>{}),
      );
      expect(empty['ok'], isFalse);
      expect(empty['error'], '缺少 elements 参数');

      final Map<String, dynamic> noId = await exec.execute(
        _call(WbBoardTools.elementUpdate, <String, dynamic>{
          'patch': <String, dynamic>{'text': 'x'},
        }),
      );
      expect(noId['ok'], isFalse);

      final Map<String, dynamic> missingElement = await exec.execute(
        _call(WbBoardTools.elementMove, <String, dynamic>{
          'elementId': 'nope',
          'dx': 1,
        }),
      );
      expect(missingElement['ok'], isFalse);
      expect('${missingElement['error']}', contains('元素不存在'));

      expect(c.elements, isEmpty);
      expect(c.canUndo, isFalse);
    });

    test('canEdit=false：执行被拒（统一文案）且不落地；恢复后撤销仍受门禁', () async {
      final WbCanvasController c = _canvas();
      bool editable = false;
      final WbAiCanvasExecutor exec = WbAiCanvasExecutor(
        canvas: c,
        canEdit: () => editable,
      );

      // 无权限：执行被拒（统一文案），画布零改动。
      final Map<String, dynamic> denied = await exec.execute(
        _call(WbBoardTools.elementCreate, <String, dynamic>{
          'elements': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'note',
              'position': <String, dynamic>{'x': 10, 'y': 20},
            },
          ],
        }),
      );
      expect(denied['ok'], isFalse);
      expect('${denied['error']}', contains('无编辑权限'));
      expect(c.elements, isEmpty);
      expect(c.canUndo, isFalse);

      // 恢复权限：同一探针翻转后执行成功。
      editable = true;
      final AiToolCall call = _call(
        WbBoardTools.elementCreate,
        <String, dynamic>{
          'elements': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'note',
              'position': <String, dynamic>{'x': 10, 'y': 20},
            },
          ],
        },
        id: 'call_2',
      );
      expect((await exec.execute(call))['ok'], isTrue);
      expect(c.elements.length, 1);

      // 权限再次收回：执行卡「撤销」不落地（元素保留）。
      editable = false;
      exec.undo(call);
      expect(c.elements.length, 1);
    });
  });

  // -------------------------------------------------------------------------
  // 状态层 ↔ 执行器接线
  // -------------------------------------------------------------------------

  group('WbAiState 执行器接线', () {
    test('绑定执行器：approveToolCall 真实落画布，undoToolCall 整体恢复', () async {
      final WbFfiService ffi = _demoFfi();
      final WbAiAppService service = WbAiAppService(ffi: ffi)
        ..configure(_CreateToolProvider());
      final WbAiState ai = WbAiState(aiService: service);
      addTearDown(ai.dispose);

      final WbCanvasController c = _canvas();
      ai.bindExecutor(WbAiCanvasExecutor(canvas: c));

      await ai.send('整理便签');
      final String callId = ai.toolCalls.single.id;
      expect(c.elements, isEmpty); // 待确认阶段不落画布。

      await ai.approveToolCall(callId);
      expect(
        c.elements.map((WbCanvasElement e) => e.text),
        <String>['痛点', '场景'],
      );
      final AiToolCall approved = ai.toolCallById(callId)!;
      expect(approved.isSuccess, isTrue);
      expect(approved.result['affected'], 2);
      expect(approved.result['simulated'], isNot(true));
      expect(c.elements.first.bounds, const Rect.fromLTWH(10, 20, 120, 80));

      ai.undoToolCall(callId);
      expect(c.elements, isEmpty);
      expect(ai.isToolCallReverted(callId), isTrue);
      expect(ai.messages.last.content, '已撤销：element_create');
    });

    test('未绑定执行器：approveToolCall 走模拟执行且画布不受影响', () async {
      final WbFfiService ffi = _demoFfi();
      final WbAiAppService service = WbAiAppService(ffi: ffi)
        ..configure(_CreateToolProvider());
      final WbAiState ai = WbAiState(aiService: service);
      addTearDown(ai.dispose);

      final WbCanvasController c = _canvas(); // 存在但未绑定。
      await ai.send('整理便签');
      final String callId = ai.toolCalls.single.id;

      await ai.approveToolCall(callId);
      final AiToolCall approved = ai.toolCallById(callId)!;
      expect(approved.isSuccess, isTrue);
      expect(approved.result['simulated'], isTrue);
      expect(approved.result['affected'], 2);
      expect(c.elements, isEmpty);
    });

    test('执行器抛异常：工具调用标记 error 且不中断状态', () async {
      final WbFfiService ffi = _demoFfi();
      final WbAiAppService service = WbAiAppService(ffi: ffi)
        ..configure(_CreateToolProvider());
      final WbAiState ai = WbAiState(aiService: service);
      addTearDown(ai.dispose);
      ai.bindExecutor(_ThrowingExecutor());

      await ai.send('整理便签');
      final String callId = ai.toolCalls.single.id;
      await ai.approveToolCall(callId);

      final AiToolCall failed = ai.toolCallById(callId)!;
      expect(failed.isError, isTrue);
      expect(failed.error, contains('boom'));
      expect(ai.hasPendingToolCalls, isFalse);
    });
  });
}
