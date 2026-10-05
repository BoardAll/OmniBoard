/// 页面状态协同单测（R3 页结构同步，演示模式 / 不依赖 DLL）。
///
/// 出口：本地新建 / 删除 / 重命名 / 排序 → `onPageOp`（create / delete /
/// rename / move）；入口：`applyRemotePageOp` 幂等应用且不回发；
/// 兜底：`ensureRemotePage` 幂等建页（防「幽灵页」）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/state/page_state.dart';

/// 演示模式 FFI 服务（候选路径必然失败，保证测试确定性）。
WbFfiService _demoFfi() =>
    WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
      ..initialize();

/// 页结构出口调用记录。
class _PageOpCall {
  _PageOpCall(this.pageId, this.field, this.value);

  final String pageId;
  final String field;
  final Object? value;

  @override
  String toString() => '$_PageOpCall($pageId, $field, $value)';
}

void main() {
  late WbPageState pages;
  late List<_PageOpCall> ops;

  setUp(() {
    pages = WbPageState(ops: WbFfiPageOps(_demoFfi()))
      ..restore(boardId: 'b1', pages: const <WbPage>[]);
    ops = <_PageOpCall>[];
    pages.onPageOp = (String pageId, String field, Object? value) =>
        ops.add(_PageOpCall(pageId, field, value));
  });

  tearDown(() => pages.dispose());

  group('本地页结构出口', () {
    test('addPage → create op + 选中新页', () {
      final String first = pages.pages.first.id;

      pages.addPage();

      expect(pages.pages.length, 2);
      expect(pages.currentPageId, isNot(first));
      expect(ops.single.field, 'create');
      expect(ops.single.pageId, pages.currentPageId);
      expect((ops.single.value as Map)['name'], '页面 2');
    });

    test('rename / move / remove → rename / move / delete op', () {
      pages.addPage();
      ops.clear();

      pages.rename('b1-page-2', '第二页');
      pages.move('b1-page-2', 0);
      pages.remove('b1-page-2');

      expect(ops.map((_PageOpCall o) => '${o.pageId}:${o.field}').toList(),
          <String>['b1-page-2:rename', 'b1-page-2:move', 'b1-page-2:delete']);
      expect(ops[0].value, '第二页');
      expect(ops[1].value, 0);
      expect(ops[2].value, true);
    });

    test('仅剩一页：remove 被拦截（不出 op）', () {
      pages.remove(pages.pages.first.id);

      expect(pages.pages.length, 1);
      expect(ops, isEmpty);
    });

    test('moveMany → 每个移动页的最终索引', () {
      pages.addPage();
      pages.addPage(); // [page-1, page-2, page-3]，当前 page-3
      ops.clear();

      pages.moveMany(<String>['b1-page-3'], 0); // 移到首位

      expect(
        pages.pages.map((WbPage p) => p.id).toList(),
        <String>['b1-page-3', 'b1-page-1', 'b1-page-2'],
      );
      expect(ops.map((_PageOpCall o) => '${o.pageId}:${o.value}').toList(),
          <String>['b1-page-3:0']);
    });
  });

  group('远端页结构应用', () {
    test('create：追加命名 / 缺省兜底 / 幂等且不回发', () {
      pages.applyRemotePageOp(
        'page-2',
        'create',
        <String, dynamic>{'name': '远端页'},
      );

      expect(
        pages.pages.map((WbPage p) => p.id).toList(),
        <String>['b1-page-1', 'page-2'],
      );
      expect(pages.pages.last.name, '远端页');

      // 重复 create：幂等忽略（名称不被覆盖）。
      pages.applyRemotePageOp(
        'page-2',
        'create',
        <String, dynamic>{'name': '重复创建'},
      );
      expect(pages.pages.length, 2);
      expect(pages.pages.last.name, '远端页');

      // 名称缺省：回退「页面 N」。
      pages.applyRemotePageOp('page-9', 'create', null);
      expect(pages.pages.last.name, '页面 3');

      expect(ops, isEmpty); // 远端应用不回发
    });

    test('rename / move：按 id 修改与重排（未知 id 忽略）', () {
      pages.addPage(); // b1-page-2
      ops.clear(); // 本地新建的 create op 不参与本用例断言

      pages.applyRemotePageOp('b1-page-2', 'rename', '同步名');
      expect(pages.pages.last.name, '同步名');

      pages.applyRemotePageOp('b1-page-2', 'move', 0);
      expect(pages.pages.first.id, 'b1-page-2');

      pages.applyRemotePageOp('unknown', 'rename', 'x');
      pages.applyRemotePageOp('unknown', 'move', 0);
      pages.applyRemotePageOp('b1-page-2', 'rename', '');
      pages.applyRemotePageOp('b1-page-2', 'settings', 1); // 未知字段
      expect(pages.pages.first.name, '同步名');
      expect(ops, isEmpty);
    });

    test('delete：当前页被删切到第一页；仅剩一页保底', () {
      pages.addPage(); // 当前 b1-page-2
      ops.clear(); // 本地新建的 create op 不参与本用例断言
      expect(pages.currentPageId, 'b1-page-2');

      pages.applyRemotePageOp('b1-page-2', 'delete', true);

      expect(pages.pages.single.id, 'b1-page-1');
      expect(pages.currentPageId, 'b1-page-1');

      // 仅剩一页：删除被拦截（至少一页）。
      pages.applyRemotePageOp('b1-page-1', 'delete', true);
      expect(pages.pages.length, 1);
      expect(ops, isEmpty);
    });

    test('ensureRemotePage：幂等建页 / 缺省名 / 不回发', () {
      pages.ensureRemotePage('page-7');
      expect(pages.pages.length, 2);
      expect(pages.pages.last.id, 'page-7');
      expect(pages.pages.last.name, '页面 2');

      pages.ensureRemotePage('page-7');
      pages.ensureRemotePage('');
      expect(pages.pages.length, 2);
      expect(ops, isEmpty);
    });
  });
}
