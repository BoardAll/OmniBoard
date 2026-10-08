/// 存档 → 引擎恢复测试（`restoreWbArchive` + `readWbArchive`）。
///
/// 覆盖多页恢复的对齐规则：同 id 复用（字段回写引擎）、缺页新建
/// （引擎 id 映射 / 当前页随之映射）、余页删除（孤儿清理）、引擎不可用
/// 或异常降级（按存档 id 原样输出），以及存档读取的宽容语义
/// （无 / 损坏 / 正常）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/services/board_file_codec.dart';
import 'package:whiteboard_canvas/state/page_state.dart';
import 'package:whiteboard_core/wb_core_common.dart';
import 'package:whiteboard_web/services/wb_archive_restore.dart';
import 'package:whiteboard_web/services/wb_browser_io.dart';

/// 记录调用的假页桥（引擎侧对齐断言用）。
class _FakePageOps implements WbPageOps {
  /// 调用记录（`op::参数` 串）。
  final List<String> calls = <String>[];

  /// isAvailable 返回值（false 模拟引擎不可用）。
  bool available = true;

  /// create 抛错开关（模拟引擎异常）。
  bool failCreate = false;

  int _seq = 0;

  @override
  bool get isAvailable => available;

  @override
  WbPage create(String boardId, [Map<String, dynamic> options = const {}]) {
    calls.add('create::$boardId');
    if (failCreate) {
      throw StateError('engine down');
    }
    _seq++;
    return WbPage(
      id: 'engine-page-$_seq',
      name: options['name'] is String ? options['name'] as String : '',
    );
  }

  @override
  WbPage rename(String pageId, String name) {
    calls.add('rename::$pageId::$name');
    return WbPage(id: pageId, name: name);
  }

  @override
  void delete(String pageId) => calls.add('delete::$pageId');

  @override
  WbPage duplicate(String pageId) => throw UnimplementedError();

  @override
  void move(String pageId, int newIndex) =>
      calls.add('move::$pageId#$newIndex');

  @override
  void lock(String pageId, bool locked) => calls.add('lock::$pageId#$locked');

  @override
  void hide(String pageId, bool hidden) => calls.add('hide::$pageId#$hidden');

  @override
  void setBackground(String pageId, Map<String, dynamic> background) =>
      calls.add('bg::$pageId');
}

/// 构造便签元素。
WbCanvasElement _note(String id) => WbCanvasElement(
      id: id,
      type: WbElementKind.note,
      x: 0,
      y: 0,
      width: 120,
      height: 80,
    );

/// 构造存档页。
WbBoardPageData _page(
  String id, {
  String name = '',
  List<WbCanvasElement> elements = const <WbCanvasElement>[],
  Map<String, dynamic>? background,
}) =>
    WbBoardPageData(
      id: id,
      name: name,
      background: background,
      elements: elements,
    );

void main() {
  group('restoreWbArchive 引擎对齐', () {
    test('同 id 复用：不新建，字段回写引擎', () {
      final _FakePageOps ops = _FakePageOps();
      final WbArchiveRestoreResult result = restoreWbArchive(
        archive: WbBoardData(
          boardId: 'b1',
          currentPageId: 'page-1',
          pages: <WbBoardPageData>[
            _page(
              'page-1',
              name: '首页',
              background: <String, dynamic>{'preset': 'grid'},
              elements: <WbCanvasElement>[_note('n1')],
            ),
          ],
        ),
        ops: ops,
        boardId: 'b1',
        enginePages: <WbPage>[const WbPage(id: 'page-1', name: '页面 1')],
      );

      expect(result.pages.single.id, 'page-1');
      expect(result.pages.single.name, '首页');
      expect(result.pages.single.elementCount, 1);
      expect(result.currentPageId, 'page-1');
      expect(result.elementsByPage['page-1']!.single.id, 'n1');
      expect(ops.calls, contains('rename::page-1::首页'));
      expect(ops.calls, contains('bg::page-1'));
      expect(ops.calls, isNot(contains('create::b1')));
      expect(ops.calls, isNot(contains('delete::page-1')));
    });

    test('缺页新建：id 与当前页随引擎返回映射', () {
      final _FakePageOps ops = _FakePageOps();
      final WbArchiveRestoreResult result = restoreWbArchive(
        archive: WbBoardData(
          boardId: 'b1',
          currentPageId: 'page-2',
          pages: <WbBoardPageData>[
            _page('page-1', elements: <WbCanvasElement>[_note('n1')]),
            _page('page-2', elements: <WbCanvasElement>[_note('n2')]),
          ],
        ),
        ops: ops,
        boardId: 'b1',
        // 引擎新实例默认页只有 page-1：page-2 需新建。
        enginePages: <WbPage>[const WbPage(id: 'page-1', name: '页面 1')],
      );

      expect(
        result.pages.map((WbPage page) => page.id),
        <String>['page-1', 'engine-page-1'],
      );
      expect(result.currentPageId, 'engine-page-1');
      expect(result.elementsByPage['page-1']!.single.id, 'n1');
      expect(result.elementsByPage['engine-page-1']!.single.id, 'n2');
      expect(
        ops.calls.where((String call) => call.startsWith('create')),
        hasLength(1),
      );
    });

    test('孤儿清理：引擎余页删除', () {
      final _FakePageOps ops = _FakePageOps();
      restoreWbArchive(
        archive: WbBoardData(
          boardId: 'b1',
          currentPageId: 'page-2',
          pages: <WbBoardPageData>[_page('page-2')],
        ),
        ops: ops,
        boardId: 'b1',
        enginePages: <WbPage>[
          const WbPage(id: 'page-1', name: '页面 1'),
          const WbPage(id: 'page-9', name: '导入残留'),
        ],
      );

      expect(ops.calls, contains('delete::page-1'));
      expect(ops.calls, contains('delete::page-9'));
      // page-2 不在引擎 → 新建（engine-page-1）。
      expect(
        ops.calls.where((String call) => call.startsWith('create')),
        hasLength(1),
      );
    });

    test('引擎不可用：按存档 id 原样输出且无引擎调用', () {
      final _FakePageOps ops = _FakePageOps()..available = false;
      final WbArchiveRestoreResult result = restoreWbArchive(
        archive: WbBoardData(
          boardId: 'b1',
          currentPageId: 'p2',
          pages: <WbBoardPageData>[_page('p1'), _page('p2')],
        ),
        ops: ops,
        boardId: 'b1',
      );

      expect(result.pages.map((WbPage page) => page.id), <String>['p1', 'p2']);
      expect(result.currentPageId, 'p2');
      expect(ops.calls, isEmpty);
    });

    test('引擎新建异常：回退存档 id（不抛异常）', () {
      final _FakePageOps ops = _FakePageOps()..failCreate = true;
      final WbArchiveRestoreResult result = restoreWbArchive(
        archive: WbBoardData(
          boardId: 'b1',
          currentPageId: 'p1',
          pages: <WbBoardPageData>[
            _page('p1', elements: <WbCanvasElement>[_note('n1')]),
          ],
        ),
        ops: ops,
        boardId: 'b1',
      );

      expect(result.pages.single.id, 'p1');
      expect(result.currentPageId, 'p1');
      expect(result.elementsByPage['p1']!.single.id, 'n1');
    });

    test('当前页无效时回退第一页', () {
      final _FakePageOps ops = _FakePageOps()..available = false;
      final WbArchiveRestoreResult result = restoreWbArchive(
        archive: WbBoardData(
          boardId: 'b1',
          currentPageId: 'missing',
          pages: <WbBoardPageData>[_page('p1'), _page('p2')],
        ),
        ops: ops,
        boardId: 'b1',
      );

      expect(result.currentPageId, 'p1');
    });
  });

  group('readWbArchive', () {
    test('无存档返回 null', () {
      expect(readWbArchive(WbMemoryCanvasStorage(), 'b1'), isNull);
    });

    test('损坏存档返回 null（不抛异常）', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      storage.write('wb.canvas.b1', 'not-json');
      expect(readWbArchive(storage, 'b1'), isNull);
    });

    test('正常存档解码（含 currentPageId）', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      storage.write(
        'wb.canvas.b1',
        WbBoardFileCodec.encode(
          WbBoardData(
            boardId: 'b1',
            currentPageId: 'p2',
            pages: <WbBoardPageData>[_page('p1'), _page('p2')],
          ),
        ),
      );
      final WbBoardData? data = readWbArchive(storage, 'b1');
      expect(data, isNotNull);
      expect(data!.currentPageId, 'p2');
      expect(data.pages, hasLength(2));
    });
  });
}
