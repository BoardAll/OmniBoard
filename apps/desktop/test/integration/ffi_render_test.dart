// §7.2 FFI 集成（真实 wb_core.dll）：显示列表 / 3D 渲染 / 缩略图 / 缓存与性能。
//
// 已知引擎偏差（记录、不修复）以"当前行为"断言固化，引擎侧修复后需同步更新：
// ① wb_render_display_list 转发的 op `renderDisplayList` 不存在于 render 域；
// ② wb_render_dirty 转发的 op `renderDirty` 不存在于 render 域；
// ③ wb_get_display_list 契约参数是 handle，但 render 域按 pageId 查找
//    （表现为 `unknown page: `，空 id）。
// 可用的显示列表路径是工具 `render.getDisplayList`，本文件用它做正向断言。
import 'dart:convert';

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

  Map<String, dynamic> sticky(String id, double x, double y) =>
      <String, dynamic>{
        'id': id,
        'type': 'sticky',
        'position': <String, dynamic>{'x': x, 'y': y},
        'size': <String, dynamic>{'width': 180, 'height': 120},
        'text': '渲染用例',
      };

  test('显示列表（工具路径）：items / count / dirtyRect 与元素对应', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 显示列表');
    final WbBoardService boards = WbBoardService(ffi);
    WbElementService(ffi).create(probe.pageId, sticky('ffi-render-dl-1', 10, 20));

    final Map<String, dynamic> dl = boards.executeTool(
      'render.getDisplayList',
      <String, dynamic>{'pageId': probe.pageId},
    );
    expect(dl['pageId'], probe.pageId);
    expect(dl['layer'], 'all');
    expect(dl['pageHidden'], isFalse);

    final List<Map<String, dynamic>> items = WbJsonCodec.extractList(dl['items']);
    expect((dl['count'] as num).toInt(), items.length);
    expect(items, isNotEmpty);

    final Map<String, dynamic> stickyItem = items.firstWhere(
      (Map<String, dynamic> m) => m['elementId'] == 'ffi-render-dl-1',
    );
    expect(stickyItem['type'], 'sticky');
    expect(stickyItem['layer'], 'Dynamic');
    expect((stickyItem['opacity'] as num).toDouble(), 1.0);
    final Map<String, dynamic> bounds =
        Map<String, dynamic>.from(stickyItem['bounds'] as Map<dynamic, dynamic>);
    expect((bounds['x'] as num).toDouble(), 10.0);
    expect((bounds['y'] as num).toDouble(), 20.0);
    expect((bounds['width'] as num).toDouble(), 180.0);
    expect((bounds['height'] as num).toDouble(), 120.0);

    final Map<String, dynamic> dirty =
        Map<String, dynamic>.from(dl['dirtyRect'] as Map<dynamic, dynamic>);
    expect(dirty.keys, containsAll(<String>['x', 'y', 'width', 'height']));
  }, skip: skipReason);

  test('3D：创建（wb_3d_create）与渲染（wb_render_3d / wb_3d_render）', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 3D 渲染');

    final Map<String, dynamic> created = WbResponse.parse(
      ffi.call2(
        ffi.bindings.wb3dCreate,
        probe.pageId,
        jsonEncode(<String, dynamic>{
          'position': <String, dynamic>{'x': 10, 'y': 20},
          'size': <String, dynamic>{'width': 200, 'height': 150},
        }),
      ),
    ).requireResult();
    final String elementId = created['elementId'] as String;
    expect(elementId, isNotEmpty);
    expect(created['geometryType'], 'box');
    expect((created['faceCount'] as num).toInt(), 6);
    expect((created['vertexCount'] as num).toInt(), 8);
    expect(WbJsonCodec.extractList(created['faces']).length, 6);
    expect(created['type'], 'render3d');

    final WbRenderService render = WbRenderService(ffi);
    final Map<String, dynamic> rendered =
        render.render3d(probe.handle, elementId, 320, 240);
    expect(rendered['elementId'], elementId);
    expect((rendered['width'] as num).toInt(), 320);
    expect((rendered['height'] as num).toInt(), 240);
    expect((rendered['faceCount'] as num).toInt(), 6);
    expect((rendered['vertexCount'] as num).toInt(), 8);
    expect((rendered['triangleCount'] as num).toInt(), 12);
    expect((rendered['lightCount'] as num).toInt(), greaterThanOrEqualTo(1));
    expect(rendered['offscreen'], isTrue);
    expect(rendered['jobId'], isA<String>());
    expect(rendered['camera'], isA<Map<dynamic, dynamic>>());

    // wb.h 中另有一个符号 wb_3d_render（P1I2），同样可用。
    final Map<String, dynamic> rawRender = WbResponse.parse(
      ffi.call1Int2(ffi.bindings.wb3dRender, elementId, 320, 240),
    ).requireResult();
    expect(rawRender['elementId'], elementId);
    expect((rawRender['width'] as num).toInt(), 320);
  }, skip: skipReason);

  test('缩略图：尺寸 / 字节数 / 缓存键 / 元素数量', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 缩略图');
    WbElementService(ffi)
        .create(probe.pageId, sticky('ffi-render-thumb-1', 0, 0));
    ffi.call2(
      ffi.bindings.wb3dCreate,
      probe.pageId,
      jsonEncode(<String, dynamic>{
        'position': <String, dynamic>{'x': 0, 'y': 0},
        'size': <String, dynamic>{'width': 100, 'height': 80},
      }),
    );

    final WbRenderService render = WbRenderService(ffi);
    final Map<String, dynamic> t160 =
        WbJsonCodec.unwrap(render.thumbnail(probe.pageId, 160, 120), 'thumbnail');
    expect(t160['format'], 'rgba');
    expect((t160['width'] as num).toInt(), 160);
    expect((t160['height'] as num).toInt(), 120);
    expect((t160['bytes'] as num).toInt(), 160 * 120 * 4);
    expect(t160['cacheKey'], 'thumb:${probe.pageId}:160x120');
    expect((t160['elementCount'] as num).toInt(), 2);

    // 宽高为 0 时使用引擎默认尺寸 16x16。
    final Map<String, dynamic> tDefault =
        WbJsonCodec.unwrap(render.thumbnail(probe.pageId), 'thumbnail');
    expect((tDefault['width'] as num).toInt(), 16);
    expect((tDefault['height'] as num).toInt(), 16);
    expect((tDefault['bytes'] as num).toInt(), 16 * 16 * 4);
    expect(tDefault['cacheKey'], 'thumb:${probe.pageId}:16x16');
  }, skip: skipReason);

  test('缓存与性能统计：结构不变量', () {
    final WbRenderService render = WbRenderService(ffi);

    final Map<String, dynamic> cache =
        WbJsonCodec.unwrap(render.cacheStats(), 'cache');
    expect((cache['maxEntries'] as num).toInt(), 256);
    expect((cache['entries'] as num).toInt(), greaterThanOrEqualTo(0));
    expect((cache['bytes'] as num).toInt(), greaterThanOrEqualTo(0));
    expect(
      (cache['hitRate'] as num).toDouble(),
      inInclusiveRange(0.0, 1.0),
    );

    final Map<String, dynamic> perf = render.perfStats();
    expect(
      perf.keys,
      containsAll(<String>[
        'fps',
        'frames',
        'drawCalls',
        'avgFrameMs',
        'lastFrameMs',
      ]),
    );
    expect((perf['frames'] as num).toInt(), greaterThanOrEqualTo(0));
    expect((perf['fps'] as num).toDouble(), greaterThanOrEqualTo(0.0));
    expect((perf['drawCalls'] as num).toInt(), greaterThanOrEqualTo(0));
  }, skip: skipReason);

  test('已知偏差①②③（记录、不修复）：显示列表三个入口的当前行为', () {
    final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 渲染偏差');
    WbElementService(ffi).create(probe.pageId, sticky('ffi-render-defect-1', 0, 0));
    final WbRenderService render = WbRenderService(ffi);

    // ③ 服务传 handle，render 域按 pageId 查找（空 id）→ NotFound。
    expect(
      () => render.displayList(probe.handle),
      throwsA(
        isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'NotFound')
            .having((WbCoreException e) => e.message, 'message',
                startsWith('unknown page')),
      ),
    );

    // ① op 名在 render 域不存在。
    expect(
      () => render.renderDisplayList(probe.pageId),
      throwsA(
        isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'NotFound')
            .having((WbCoreException e) => e.message, 'message',
                'unknown render op: renderDisplayList'),
      ),
    );

    // ② op 名在 render 域不存在。
    expect(
      () => render.renderDirty(probe.pageId),
      throwsA(
        isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'NotFound')
            .having((WbCoreException e) => e.message, 'message',
                'unknown render op: renderDirty'),
      ),
    );
  }, skip: skipReason);
}
