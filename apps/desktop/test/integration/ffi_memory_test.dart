// §7.2 FFI 集成（真实 wb_core.dll）：内存卫生（UTF-8 往返 / 句柄循环）与
// 渲染缓存的命中统计、错误处理。
//
// 相对增量断言的前提：`flutter test` 多文件并发时引擎状态进程级共享，但只有
// 本文件调用 cacheClear，且本文件内用例按声明顺序串行执行，因此"先取材再
// 断言"的窗口内其他文件只会追加缓存条目、不会清空。
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

  test('UTF-8 文本往返：中文与 emoji 经 create → list → update 保持一致', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 内存 UTF-8');
    final WbElementService elements = WbElementService(ffi);
    const String text = 'FFI 内存探针 🧠✓ 中文文本';
    const String updatedText = '更新后的 ✅ 文本';

    elements.create(probe.pageId, <String, dynamic>{
      'id': 'ffi-mem-utf8-1',
      'type': 'sticky',
      'position': <String, dynamic>{'x': 0, 'y': 0},
      'size': <String, dynamic>{'width': 120, 'height': 90},
      'text': text,
    });
    final WbElement listed = elements
        .list(probe.pageId)
        .firstWhere((WbElement e) => e.id == 'ffi-mem-utf8-1');
    expect(listed['text'], text);

    elements.update('ffi-mem-utf8-1', <String, dynamic>{'text': updatedText});
    final WbElement updated = elements
        .list(probe.pageId)
        .firstWhere((WbElement e) => e.id == 'ffi-mem-utf8-1');
    expect(updated['text'], updatedText);

    elements.delete('ffi-mem-utf8-1');
  }, skip: skipReason);

  test('句柄循环：连续创建/销毁 10 个白板后引擎仍可用', () {
    final WbBoardService boards = WbBoardService(ffi);
    for (int i = 0; i < 10; i++) {
      final int handle = boards.create(name: 'FFI 句柄循环 $i');
      expect(handle, greaterThan(0));
      expect(boards.get(handle).id, matches(RegExp(r'^board-\d+$')));
      boards.destroy(handle);
    }

    final FfiBoardHandle last = createBoardWithPage(ffi, 'FFI 句柄循环收尾');
    expect(last.handle, greaterThan(0));
    expect(last.board.pages, isNotEmpty);
    boards.destroy(last.handle);
  }, skip: skipReason);

  test('缓存：首次未命中 → 同尺寸再次命中（相对增量断言）', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 缓存探针');
    WbElementService(ffi).create(probe.pageId, <String, dynamic>{
      'id': 'ffi-mem-cache-1',
      'type': 'sticky',
      'position': <String, dynamic>{'x': 0, 'y': 0},
      'size': <String, dynamic>{'width': 100, 'height': 80},
      'text': '缓存统计',
    });
    final WbRenderService render = WbRenderService(ffi);

    final Map<String, dynamic> c0 =
        WbJsonCodec.unwrap(render.cacheStats(), 'cache');
    render.thumbnail(probe.pageId, 111, 83);
    final Map<String, dynamic> c1 =
        WbJsonCodec.unwrap(render.cacheStats(), 'cache');
    render.thumbnail(probe.pageId, 111, 83);
    final Map<String, dynamic> c2 =
        WbJsonCodec.unwrap(render.cacheStats(), 'cache');

    final int miss0 = (c0['misses'] as num).toInt();
    final int miss1 = (c1['misses'] as num).toInt();
    final int hit1 = (c1['hits'] as num).toInt();
    final int hit2 = (c2['hits'] as num).toInt();
    expect(miss1, greaterThanOrEqualTo(miss0 + 1), reason: '首次渲染应至少一次未命中');
    expect(hit2, greaterThanOrEqualTo(hit1 + 1), reason: '同尺寸再次渲染应命中缓存');
    expect((c1['entries'] as num).toInt(), greaterThanOrEqualTo(1));
  }, skip: skipReason);

  test('缓存清空：cleared 计数不小于清空前 entries（并发下只追加）', () {
    final WbRenderService render = WbRenderService(ffi);
    final int before = (WbJsonCodec.unwrap(render.cacheStats(), 'cache')['entries']
            as num)
        .toInt();

    final Map<String, dynamic> cleared = render.cacheClear();
    expect((cleared['cleared'] as num).toInt(), greaterThanOrEqualTo(before));
  }, skip: skipReason);

  test('错误处理：未知页面 / 无效 JSON 返回错误信封，requireResult 抛异常', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 内存错误');
    final WbRenderService render = WbRenderService(ffi);

    final WbResponse unknownPage = WbResponse.parse(
      ffi.call1(ffi.bindings.wbElementList, 'no-such-page'),
    );
    expect(unknownPage.ok, isFalse);
    expect(unknownPage.code, 'NotFound');
    expect(unknownPage.message, 'unknown page: no-such-page');

    final WbResponse unknownThumb = WbResponse.parse(
      ffi.call1Int2(ffi.bindings.wbRenderThumbnail, 'no-such-page', 0, 0),
    );
    expect(unknownThumb.ok, isFalse);
    expect(unknownThumb.code, 'NotFound');

    final WbResponse badCommand = WbResponse.parse(
      ffi.callHandle1(ffi.bindings.wbExecuteCommand, probe.handle, 'not-json'),
    );
    expect(badCommand.ok, isFalse);
    expect(badCommand.code, 'InvalidArgument');

    final WbResponse badElement = WbResponse.parse(
      ffi.call2(ffi.bindings.wbElementCreate, probe.pageId, 'not-json'),
    );
    expect(badElement.ok, isFalse);
    expect(badElement.code, 'InvalidArgument');
    expect(badElement.message, 'args.element is required');

    expect(() => unknownPage.requireResult(), throwsA(isA<WbCoreException>()));
    expect(() => badCommand.requireResult(), throwsA(isA<WbCoreException>()));
    expect(
      () => render.thumbnail('no-such-page'),
      throwsA(
        isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'NotFound'),
      ),
    );
  }, skip: skipReason);
}
