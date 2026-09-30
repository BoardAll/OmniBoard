/// T1.6 画布协同接线测试：控制器出口（落定提交 → op）/ 入口
/// （远端 ops → 画布）/ 防回发 / 撤销栈边界（fake 引擎，不依赖 DLL）。
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/services/board_file_codec.dart';
import 'package:whiteboard_desktop/services/sync_service.dart';
import 'package:whiteboard_desktop/state/selection_state.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_controller.dart';
import 'package:whiteboard_desktop/widgets/canvas/canvas_model.dart';

import 'support/fake_collab_engine.dart';

/// 构造 `el:{id}:data` 远端 op。
Map<String, dynamic> _dataOp(WbCanvasElement element) => <String, dynamic>{
      'key': 'el:${element.id}:data',
      'value': WbBoardFileCodec.encodeElement(element),
    };

void main() {
  late FakeCollabEngine engine;
  late FakePollTimerFactory timers;
  late WbCollabService service;
  late WbSelectionState selection;
  late WbCanvasController controller;

  setUp(() async {
    engine = FakeCollabEngine();
    timers = FakePollTimerFactory();
    service = WbCollabService(
      engine: engine,
      sleep: (Duration _) async {},
      pollTimerFactory: timers.create,
      actorGenerator: () => 'wb-hooks-actor',
      clock: () => DateTime(2026, 9, 30, 12),
    );
    selection = WbSelectionState();
    controller = WbCanvasController(selection: selection);
    // 与 `board_edit_page` 一致的接线（出口 / 防回发谓词 / 入口回调）。
    controller.onLocalCommit = service.handleCanvasCommit;
    controller.isRemoteApplying = () => service.isApplyingRemote;
    service.onRemoteElement = controller.applyRemoteElement;
    service.onRemoteRemove = controller.applyRemoteRemove;
    addTearDown(() {
      controller.dispose();
      service.dispose();
    });
    await service.start(boardId: 'b1');
  });

  // ---- 出口（本地落定提交 → op） ------------------------------------------

  group('画布出口', () {
    test('本地插入（note）：落定提交生成 el:{id}:data 契约 JSON', () {
      final WbCanvasElement element = controller.insertElement(
        type: WbElementKind.note,
        size: const Size(120, 80),
      );

      expect(engine.sentOps.length, 1);
      final Map<String, dynamic> op = engine.sentOps.single;
      expect(op['key'], 'el:${element.id}:data');
      expect(op['value'], WbBoardFileCodec.encodeElement(element));
      expect(op['actor'], 'fake-actor');
    });

    test('几何变更（resize）：data op 含新尺寸', () {
      final WbCanvasElement element = controller.insertElement(
        type: WbElementKind.note,
        size: const Size(120, 80),
      );
      engine.sentOps.clear();

      controller.resizeElementById(element.id, 200, 150);

      expect(engine.sentOps.length, 1);
      final Map<String, dynamic> value =
          Map<String, dynamic>.from(engine.sentOps.single['value'] as Map);
      expect((value['size'] as Map)['width'], 200);
      expect((value['size'] as Map)['height'], 150);
    });

    test('删除（removeElement）：el:{id}:exists=false', () {
      final WbCanvasElement element = controller.insertElement(
        type: WbElementKind.note,
        size: const Size(120, 80),
      );
      engine.sentOps.clear();

      controller.removeElement(element.id);

      expect(engine.sentOps.single['key'], 'el:${element.id}:exists');
      expect(engine.sentOps.single['value'], isFalse);
    });

    test('批量删除（deleteSelected）：逐元素 exists=false', () {
      controller.insertElement(
        type: WbElementKind.note,
        size: const Size(120, 80),
      );
      controller.insertElement(
        type: WbElementKind.note,
        size: const Size(120, 80),
      );
      engine.sentOps.clear();

      controller.selectAll();
      controller.deleteSelected();

      expect(engine.sentOps.length, 2);
      for (final Map<String, dynamic> op in engine.sentOps) {
        expect(op['key'], endsWith(':exists'));
        expect(op['value'], isFalse);
      }
    });

    test('drawing 笔迹：整元素 JSON 含 points', () {
      final List<WbCanvasElement> created =
          controller.insertElements(<WbElementSpec>[
        const WbElementSpec(
          type: WbElementKind.drawing,
          points: <Offset>[Offset(0, 0), Offset(10, 20), Offset(30, 40)],
        ),
      ]);
      final WbCanvasElement element = created.single;

      expect(engine.sentOps.length, 1);
      final Map<String, dynamic> op = engine.sentOps.single;
      expect(op['key'], 'el:${element.id}:data');
      expect(op['value'], WbBoardFileCodec.encodeElement(element));
      final Map<String, dynamic> value =
          Map<String, dynamic>.from(op['value'] as Map);
      expect((value['points'] as List).length, 3);
    });

    test('专业元素（flowchart）：整元素 JSON 走同一出口（M1 不细化）', () {
      final WbCanvasElement element = controller.insertElement(
        type: WbElementKind.flowchart,
        size: const Size(320, 200),
        payload: <String, dynamic>{'direction': 'TB'},
      );

      expect(engine.sentOps.length, 1);
      final Map<String, dynamic> op = engine.sentOps.single;
      expect(op['key'], 'el:${element.id}:data');
      expect(op['value'], WbBoardFileCodec.encodeElement(element));
      expect((op['value'] as Map)['type'], WbElementKind.flowchart);
    });
  });

  // ---- 入口（远端 ops → 画布） --------------------------------------------

  group('画布入口', () {
    test('远端 data op：轮询应用 upsert；同 id 覆盖（LWW）', () {
      const WbCanvasElement v1 = WbCanvasElement(
        id: 'r1',
        type: WbElementKind.note,
        x: 0,
        y: 0,
        width: 100,
        height: 80,
      );

      engine.nextOps = <Map<String, dynamic>>[_dataOp(v1)];
      timers.fire();

      expect(
        controller.elements.where((WbCanvasElement e) => e.id == 'r1').single.width,
        100,
      );

      final WbCanvasElement v2 = v1.copyWith(x: 40, width: 220);
      engine.nextOps = <Map<String, dynamic>>[_dataOp(v2)];
      timers.fire();

      expect(
        controller.elements.where((WbCanvasElement e) => e.id == 'r1').length,
        1,
      );
      expect(
        controller.elements.where((WbCanvasElement e) => e.id == 'r1').single.width,
        220,
      );
      expect(engine.sentOps, isEmpty); // 应用远端不回发
    });

    test('远端 exists=false：删除 + 选区剔除', () {
      final WbCanvasElement element = controller.insertElement(
        type: WbElementKind.note,
        size: const Size(120, 80),
      );
      selection.select(<String>[element.id]);
      expect(selection.contains(element.id), isTrue);
      engine.sentOps.clear();

      engine.nextOps = <Map<String, dynamic>>[
        <String, dynamic>{'key': 'el:${element.id}:exists', 'value': false},
      ];
      timers.fire();

      expect(
        controller.elements.where((WbCanvasElement e) => e.id == element.id),
        isEmpty,
      );
      expect(selection.contains(element.id), isFalse);
      expect(engine.sentOps, isEmpty);
    });

    test('远端应用不入撤销栈：undo 只消耗本地步', () {
      controller.insertElement(
        type: WbElementKind.note,
        size: const Size(120, 80),
      );
      expect(controller.undoDepth, 1);

      engine.nextOps = <Map<String, dynamic>>[
        _dataOp(const WbCanvasElement(
          id: 'r9',
          type: WbElementKind.note,
          x: 0,
          y: 0,
          width: 100,
          height: 80,
        )),
      ];
      timers.fire();
      expect(controller.undoDepth, 1); // 远端应用未污染撤销栈

      controller.undo();
      expect(controller.canUndo, isFalse); // 一次撤销消耗本地那步
      // 快照式撤销整体回退（含远端元素；M1 已知折衷，差异优化留 M2）。
      expect(controller.elements, isEmpty);
    });

    test('防回发：远端应用窗口内画布出口跳过（控制器侧）', () {
      bool? inside;
      service.onRemoteElement = (WbCanvasElement element) {
        inside = service.isApplyingRemote;
        controller.applyRemoteElement(element);
        // 窗口内本地提交（模拟回调链触发）：应被出口跳过。
        controller.insertElement(
          type: WbElementKind.note,
          size: const Size(60, 60),
        );
      };

      engine.nextOps = <Map<String, dynamic>>[
        _dataOp(const WbCanvasElement(
          id: 'r1',
          type: WbElementKind.note,
          x: 0,
          y: 0,
          width: 100,
          height: 80,
        )),
      ];
      timers.fire();

      expect(inside, isTrue);
      expect(engine.sentOps, isEmpty); // 未回发
      expect(controller.elements.length, 2); // 窗口内插入本地生效（仅未广播）
    });

    test('未接线回调为 null：远端应用安全空转', () {
      service.onRemoteElement = null;
      service.onRemoteRemove = null;

      engine.nextOps = <Map<String, dynamic>>[
        _dataOp(const WbCanvasElement(
          id: 'r1',
          type: WbElementKind.note,
          x: 0,
          y: 0,
          width: 100,
          height: 80,
        )),
        <String, dynamic>{'key': 'el:r2:exists', 'value': false},
      ];
      timers.fire(); // 不抛

      expect(service.lastSyncedAt, isNotNull);
      expect(controller.elements, isEmpty);
    });
  });
}
