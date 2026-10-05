/// 持久化画布存储测试（`WbPersistentCanvasStore` + 浏览器 IO 桩）。
///
/// VM 环境（`flutter test`）条件导入解析为桩实现：内存存储可用、
/// 下载 no-op、文件选择恒 null；Web 真实路径（localStorage / Blob
/// 下载 / 文件选择）由浏览器实测覆盖。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/canvas/canvas_store.dart';
import 'package:whiteboard_canvas/services/board_file_codec.dart';
import 'package:whiteboard_web/services/wb_browser_io.dart';
import 'package:whiteboard_web/services/wb_persistent_canvas_store.dart';

/// 记录调用的假引擎存储（回灌 / 差量同步断言用）。
class _FakeEngineStore implements WbCanvasStore {
  /// 各页元素（引擎侧状态）。
  final Map<String, List<WbCanvasElement>> pages =
      <String, List<WbCanvasElement>>{};

  /// `upsert` 调用记录（元素 id 顺序）。
  final List<String> upsertCalls = <String>[];

  /// `remove` 调用记录（元素 id 顺序）。
  final List<String> removeCalls = <String>[];

  /// 为 true 时 `load` 抛错（引擎故障模拟）。
  bool failLoad = false;

  @override
  List<WbCanvasElement> load(String pageId) {
    if (failLoad) {
      throw StateError('engine down');
    }
    return List<WbCanvasElement>.of(
      pages[pageId] ?? const <WbCanvasElement>[],
    );
  }

  @override
  void upsert(String pageId, WbCanvasElement element) {
    final List<WbCanvasElement> list = pages.putIfAbsent(
      pageId,
      () => <WbCanvasElement>[],
    );
    final int index =
        list.indexWhere((WbCanvasElement e) => e.id == element.id);
    if (index >= 0) {
      list[index] = element;
    } else {
      list.add(element);
    }
    upsertCalls.add(element.id);
  }

  @override
  void remove(String pageId, String elementId) {
    pages[pageId]?.removeWhere((WbCanvasElement e) => e.id == elementId);
    removeCalls.add(elementId);
  }

  @override
  void replaceAll(String pageId, List<WbCanvasElement> elements) {
    pages[pageId] = List<WbCanvasElement>.of(elements);
  }
}

/// 构造便签元素。
WbCanvasElement _note(
  String id, {
  String text = '',
  double x = 0,
  double y = 0,
}) =>
    WbCanvasElement(
      id: id,
      type: WbElementKind.note,
      x: x,
      y: y,
      width: 120,
      height: 80,
      text: text,
    );

void main() {
  group('WbPersistentCanvasStore 存档读写', () {
    test('无存档时 load 返回空', () {
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: WbMemoryCanvasStorage(),
        boardId: 'b1',
      );
      expect(store.load('p1'), isEmpty);
      expect(store.currentElements, isEmpty);
    });

    test('upsert 写穿存档（.wbd 格式），新实例可恢复', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
        boardName: '测试板',
      );
      store.upsert('p1', _note('n1', text: '你好', x: 8));

      final String? saved = storage.read(store.storageKey);
      expect(saved, isNotNull);
      final WbBoardData data = WbBoardFileCodec.decode(saved!);
      expect(data.boardId, 'b1');
      expect(data.boardName, '测试板');
      expect(data.pages.single.id, 'p1');
      expect(data.pages.single.elements.single.id, 'n1');
      expect(data.pages.single.elements.single.text, '你好');

      // 模拟刷新：新实例（引擎空）从存档恢复。
      final WbPersistentCanvasStore reopened = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      );
      final List<WbCanvasElement> restored = reopened.load('p1');
      expect(restored.single.id, 'n1');
      expect(restored.single.x, 8);
    });

    test('多页存档合并：各页互不覆盖，刷新后均可恢复', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      );
      store.upsert('p1', _note('n1'));
      store.upsert('p2', _note('n2'));
      // 回写 p1：p2 不丢（全量合并）。
      store.upsert('p1', _note('n1', text: 'v2'));

      final WbBoardData data = WbBoardFileCodec.decode(
        storage.read(store.storageKey)!,
      );
      expect(
        data.pages.map((WbBoardPageData page) => page.id),
        <String>['p1', 'p2'],
      );
      expect(data.currentPageId, 'p1');

      // 模拟刷新：新实例逐页恢复。
      final WbPersistentCanvasStore reopened = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      );
      expect(reopened.load('p1').single.id, 'n1');
      expect(reopened.load('p1').single.text, 'v2');
      expect(reopened.load('p2').single.id, 'n2');
    });

    test('未载入直接写 p2：p1 存档不被覆盖（先合并再写穿）', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      ).upsert('p1', _note('n1'));

      // 新实例（镜像未载入）直接操作 p2：写穿时须保留 p1。
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      );
      store.upsert('p2', _note('n2'));

      final WbBoardData data = WbBoardFileCodec.decode(
        storage.read(store.storageKey)!,
      );
      expect(
        data.pages.map((WbBoardPageData page) => page.id),
        containsAll(<String>['p1', 'p2']),
      );
    });

    test('remove 同步镜像与存档', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      );
      store.upsert('p1', _note('n1'));
      store.upsert('p1', _note('n2'));
      store.remove('p1', 'n1');

      final List<WbCanvasElement> reloaded = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      ).load('p1');
      expect(
        reloaded.map((WbCanvasElement e) => e.id),
        <String>['n2'],
      );
    });

    test('未载入直接 upsert：先恢复存档再追加（不丢已存元素）', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      ).upsert('p1', _note('n1'));

      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      );
      store.upsert('p1', _note('n2'));

      final List<WbCanvasElement> reloaded = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      ).load('p1');
      expect(
        reloaded.map((WbCanvasElement e) => e.id),
        containsAll(<String>['n1', 'n2']),
      );
    });

    test('未知页返回空（不串页），他页元素仍保留在存档', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      ).upsert('old-page', _note('n1', text: '旧'));

      final List<WbCanvasElement> restored = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      ).load('new-page');
      expect(restored, isEmpty);

      // 他页存档不受影响（切页不丢数据）。
      final List<WbCanvasElement> oldPage = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      ).load('old-page');
      expect(oldPage.single.text, '旧');
    });

    test('空页 id 回退存档页 id（fallbackPageId）', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      );
      store.upsert('', _note('n1'));

      final WbBoardData data = WbBoardFileCodec.decode(
        storage.read(store.storageKey)!,
      );
      expect(data.pages.single.id, WbPersistentCanvasStore.fallbackPageId);
      expect(store.load('').single.id, 'n1');
    });

    test('损坏存档视为无存档（不抛异常）', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      );
      storage.write(store.storageKey, 'not-json');
      expect(store.load('p1'), isEmpty);
    });
  });

  group('WbPersistentCanvasStore 引擎协同', () {
    test('load 引擎优先：引擎非空时不读存档', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      ).upsert('p1', _note('from-archive'));

      final _FakeEngineStore engine = _FakeEngineStore()
        ..upsert('p1', _note('from-engine'));
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
        engine: engine,
      );
      expect(store.load('p1').single.id, 'from-engine');
    });

    test('引擎为空时从存档恢复并回灌引擎', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      final WbPersistentCanvasStore archive = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      );
      archive.upsert('p1', _note('n1'));
      archive.upsert('p1', _note('n2'));

      final _FakeEngineStore engine = _FakeEngineStore();
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
        engine: engine,
      );
      final List<WbCanvasElement> loaded = store.load('p1');
      expect(
        loaded.map((WbCanvasElement e) => e.id),
        containsAll(<String>['n1', 'n2']),
      );
      expect(
        engine.pages['p1']!.map((WbCanvasElement e) => e.id),
        containsAll(<String>['n1', 'n2']),
      );
    });

    test('replaceAll（撤销 / 导入）写穿存档并差量同步引擎', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      final _FakeEngineStore engine = _FakeEngineStore();
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
        engine: engine,
      );
      store.upsert('p1', _note('n1', text: 'v1'));
      store.upsert('p1', _note('n2'));

      // 整体替换为 [n1 v2]：引擎侧 n1 内容覆盖、n2 删除。
      store.replaceAll('p1', <WbCanvasElement>[_note('n1', text: 'v2')]);
      expect(
        engine.pages['p1']!.map((WbCanvasElement e) => e.id),
        <String>['n1'],
      );
      expect(engine.pages['p1']!.single.text, 'v2');
      expect(engine.removeCalls, contains('n2'));

      final List<WbCanvasElement> reloaded = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
      ).load('p1');
      expect(reloaded.single.text, 'v2');
    });

    test('引擎异常：本地镜像与存档不受影响（不抛异常）', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      final _FakeEngineStore engine = _FakeEngineStore()..failLoad = true;
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
        engine: engine,
      );
      expect(store.load('p1'), isEmpty);
      store.upsert('p1', _note('n1'));
      expect(store.currentElements.single.id, 'n1');
      expect(
        WbBoardFileCodec.decode(storage.read(store.storageKey)!)
            .pages
            .single
            .elements
            .single
            .id,
        'n1',
      );
    });
  });

  group('浏览器 IO 桩', () {
    test('存储工厂：多次调用共享同一内存实例', () {
      final WbCanvasStorage a = createWbCanvasStorage();
      final WbCanvasStorage b = createWbCanvasStorage();
      expect(identical(a, b), isTrue);
      a.write('key', 'value');
      expect(b.read('key'), 'value');
      b.clear('key');
      expect(a.read('key'), isNull);
    });

    test('下载为 no-op、文件选择恒返回 null', () async {
      await wbDownloadTextFile('a.wbd', '{}');
      expect(await wbPickTextFile(), isNull);
    });
  });

  group('导出往返', () {
    test('存档文本可被 codec 解码（编码往返一致）', () {
      final WbMemoryCanvasStorage storage = WbMemoryCanvasStorage();
      final WbPersistentCanvasStore store = WbPersistentCanvasStore(
        storage: storage,
        boardId: 'b1',
        boardName: '往返',
      );
      store.upsert('p1', _note('n1', text: '往返'));
      final String text = storage.read(store.storageKey)!;

      final WbBoardData data = WbBoardFileCodec.decode(text);
      final String reencoded = WbBoardFileCodec.encode(data);
      final WbCanvasElement element =
          WbBoardFileCodec.decode(reencoded).pages.single.elements.single;
      expect(element.id, 'n1');
      expect(element.text, '往返');
    });
  });
}
