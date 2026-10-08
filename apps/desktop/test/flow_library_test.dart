/// 「我的组件」图形库基础层测试（`flow_components.dart`）：
/// - [WbFlowComponent] JSON 容错往返与放置尺寸（长边 ≤160 等比）；
/// - [WbFlowLibraryPrefs] JSON 容错往返与 [WbFlowMemoryLibraryStore] 读写；
/// - [WbFlowComponent.fromAsset] 导入归一化（判型 / 体积守卫 / PNG 重编码、
///   SVG 尺寸探测）；
/// - [WbFlowComponentCache] 图片解码缓存（命中 / 失败标记）。
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/context_editors/flowchart_editor.dart';

/// 1x1 透明 PNG 常量（真实解码用例：归一化与缓存）。
final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhf'
  'DwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const Set<String> _allLibraryIds = <String>{
  'flowchart',
  'umlClass',
  'umlSequence',
  'umlUseCase',
  'umlState',
  'dfd',
  'circuit',
  'custom',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WbFlowComponent：JSON 容错往返与放置尺寸', () {
    test('toJson / fromJson 全字段往返', () {
      const WbFlowComponent component = WbFlowComponent(
        id: 'cmp-svg',
        name: '图标',
        mime: WbFlowComponent.mimeSvg,
        data: 'PHN2Zy8+',
        width: 48,
        height: 24,
      );
      final WbFlowComponent? back = WbFlowComponent.fromJson(
        component.toJson(),
      );
      expect(back, isNotNull);
      expect(back!.id, 'cmp-svg');
      expect(back.name, '图标');
      expect(back.mime, WbFlowComponent.mimeSvg);
      expect(back.data, 'PHN2Zy8+');
      expect(back.width, 48);
      expect(back.height, 24);
      expect(back.isSvg, isTrue);
      expect(back.cacheKey, 'cmp-svg');
    });

    test('fromJson 容错：非 Map / 缺 id / mime / data → null', () {
      expect(WbFlowComponent.fromJson(null), isNull);
      expect(WbFlowComponent.fromJson('raw'), isNull);
      expect(
        WbFlowComponent.fromJson(<String, dynamic>{'id': '', 'mime': 'a', 'data': 'b'}),
        isNull,
      );
      expect(
        WbFlowComponent.fromJson(<String, dynamic>{
          'mime': WbFlowComponent.mimePng,
          'data': 'AA==',
        }),
        isNull,
      );
      expect(
        WbFlowComponent.fromJson(<String, dynamic>{'id': 'c', 'data': 'AA=='}),
        isNull,
      );
      expect(
        WbFlowComponent.fromJson(<String, dynamic>{
          'id': 'c',
          'mime': WbFlowComponent.mimePng,
        }),
        isNull,
      );
      expect(
        WbFlowComponent.fromJson(<String, dynamic>{
          'id': 'c',
          'mime': WbFlowComponent.mimePng,
          'data': '',
        }),
        isNull,
      );
    });

    test('fromJson 容错：name 缺失回退「组件」、坏尺寸回退 120', () {
      final WbFlowComponent? component = WbFlowComponent.fromJson(
        <String, dynamic>{
          'id': 'c',
          'mime': WbFlowComponent.mimePng,
          'data': 'AA==',
          'width': 0,
          'height': -3,
        },
      );
      expect(component, isNotNull);
      expect(component!.name, '组件');
      expect(component.width, 120);
      expect(component.height, 120);
      expect(component.isSvg, isFalse);
    });

    test('preferredNodeSize：长边 ≤160 等比 / 小图保留 / 坏尺寸回退 120', () {
      const WbFlowComponent small = WbFlowComponent(
        id: 's',
        name: 's',
        mime: WbFlowComponent.mimePng,
        data: 'AA==',
        width: 40,
        height: 20,
      );
      expect(small.preferredNodeSize.width, 40);
      expect(small.preferredNodeSize.height, 20);

      const WbFlowComponent tall = WbFlowComponent(
        id: 't',
        name: 't',
        mime: WbFlowComponent.mimePng,
        data: 'AA==',
        width: 100,
        height: 500,
      );
      expect(tall.preferredNodeSize.width, 32);
      expect(tall.preferredNodeSize.height, 160);

      const WbFlowComponent zero = WbFlowComponent(
        id: 'z',
        name: 'z',
        mime: WbFlowComponent.mimePng,
        data: 'AA==',
        width: 0,
        height: 0,
      );
      expect(zero.preferredNodeSize.width, 120);
      expect(zero.preferredNodeSize.height, 120);
    });
  });

  group('WbFlowLibraryPrefs / WbFlowMemoryLibraryStore', () {
    test('JSON 往返：启用库 / 折叠库 / 组件全量保留', () {
      const WbFlowComponent component = WbFlowComponent(
        id: 'cmp-prefs',
        name: '星形',
        mime: WbFlowComponent.mimePng,
        data: 'AA==',
        width: 64,
        height: 64,
      );
      const WbFlowLibraryPrefs prefs = WbFlowLibraryPrefs(
        enabledLibraries: <String>{'flowchart', 'circuit'},
        collapsedLibraries: <String>{'flowchart'},
        components: <WbFlowComponent>[component],
      );
      final WbFlowLibraryPrefs back = WbFlowLibraryPrefs.fromJson(
        prefs.toJson(),
        defaultEnabled: _allLibraryIds,
      );
      expect(back.enabledLibraries, <String>{'flowchart', 'circuit'});
      expect(back.collapsedLibraries, <String>{'flowchart'});
      expect(back.components.length, 1);
      expect(back.components.single.id, 'cmp-prefs');
      expect(back.components.single.name, '星形');
    });

    test('JSON 容错：非 Map / 坏字段回默认、坏组件条目丢弃', () {
      final WbFlowLibraryPrefs fallback = WbFlowLibraryPrefs.fromJson(
        'raw',
        defaultEnabled: _allLibraryIds,
      );
      expect(fallback.enabledLibraries, _allLibraryIds);
      expect(fallback.collapsedLibraries, isEmpty);
      expect(fallback.components, isEmpty);

      final WbFlowLibraryPrefs tolerant = WbFlowLibraryPrefs.fromJson(
        <String, dynamic>{
          'enabledLibraries': <Object>['circuit', '', 42],
          'collapsedLibraries': 'raw',
          'components': <Object>[
            <String, dynamic>{'id': 'c1', 'mime': 'a', 'data': 'b'},
            'bad',
            <String, dynamic>{'mime': 'a', 'data': 'b'},
          ],
        },
        defaultEnabled: _allLibraryIds,
      );
      // 非字符串项过滤；折叠字段非 List → 空；坏组件丢弃保留 1 个。
      expect(tolerant.enabledLibraries, <String>{'circuit'});
      expect(tolerant.collapsedLibraries, isEmpty);
      expect(tolerant.components.length, 1);
      expect(tolerant.components.single.id, 'c1');
    });

    test('WbFlowMemoryLibraryStore：read / write 忠实地保存同一实例', () {
      final WbFlowMemoryLibraryStore store = WbFlowMemoryLibraryStore();
      expect(store.read(), isNull);
      const WbFlowLibraryPrefs prefs = WbFlowLibraryPrefs(
        enabledLibraries: <String>{'custom'},
      );
      store.write(prefs);
      expect(store.read(), same(prefs));

      final WbFlowMemoryLibraryStore seeded = WbFlowMemoryLibraryStore(prefs);
      expect(seeded.read(), same(prefs));
    });
  });

  group('WbFlowComponent.fromAsset：导入归一化', () {
    test('不支持的格式（无扩展名 / 无魔数）→ FormatException', () async {
      await expectLater(
        WbFlowComponent.fromAsset(
          WbFlowComponentAsset(
            name: 'weird.xyz',
            bytes: Uint8List.fromList(<int>[0x01, 0x02, 0x03]),
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('不支持的格式'),
          ),
        ),
      );
    });

    test('SVG 体积守卫 / 缺根元素 / 非 UTF-8 → FormatException', () async {
      await expectLater(
        WbFlowComponent.fromAsset(
          WbFlowComponentAsset(
            name: 'big.svg',
            bytes: Uint8List(WbFlowComponent.maxSvgBytes + 1),
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('SVG 源文件过大'),
          ),
        ),
      );
      await expectLater(
        WbFlowComponent.fromAsset(
          WbFlowComponentAsset(
            name: 'no-root.svg',
            bytes: Uint8List.fromList(utf8.encode('<html></html>')),
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('缺少 <svg> 根元素'),
          ),
        ),
      );
      await expectLater(
        WbFlowComponent.fromAsset(
          WbFlowComponentAsset(
            name: 'bad-utf8.svg',
            bytes: Uint8List.fromList(<int>[0x3C, 0x73, 0x76, 0x67, 0xFF, 0xFE]),
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('不是有效的 UTF-8'),
          ),
        ),
      );
    });

    testWidgets('SVG 归一化：保留矢量源 + 尺寸探测', (WidgetTester tester) async {
      const String text =
          '<svg xmlns="http://www.w3.org/2000/svg" width="24" '
          'height="12"></svg>';
      await tester.runAsync(() async {
        final WbFlowComponent component = await WbFlowComponent.fromAsset(
          WbFlowComponentAsset(
            name: 'logo.svg',
            bytes: Uint8List.fromList(utf8.encode(text)),
          ),
          id: 'cmp-svg-test',
        );
        expect(component.id, 'cmp-svg-test');
        expect(component.name, 'logo');
        expect(component.mime, WbFlowComponent.mimeSvg);
        expect(component.isSvg, isTrue);
        expect(component.width, 24);
        expect(component.height, 12);
        expect(utf8.decode(base64Decode(component.data)), text);
      });
    });

    testWidgets('PNG 归一化：真实解码 + 原样重编码 PNG', (WidgetTester tester) async {
      await tester.runAsync(() async {
        final WbFlowComponent component = await WbFlowComponent.fromAsset(
          WbFlowComponentAsset(name: 'dot.png', bytes: _png1x1),
          id: 'cmp-png-test',
        );
        expect(component.id, 'cmp-png-test');
        expect(component.name, 'dot');
        expect(component.mime, WbFlowComponent.mimePng);
        expect(component.isSvg, isFalse);
        // 1x1 ≤ 长边上限：尺寸保留、数据为 PNG 字节的 base64。
        expect(component.width, 1);
        expect(component.height, 1);
        expect(component.data.startsWith('iVBOR'), isTrue);
      });
    });
  });

  group('WbFlowComponentCache：解码与失败标记', () {
    setUp(WbFlowComponentCache.resetInstance);
    tearDown(WbFlowComponentCache.resetInstance);

    testWidgets('load：PNG 解码进入缓存（imageFor 命中 1x1）', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        final WbFlowComponent component = await WbFlowComponent.fromAsset(
          WbFlowComponentAsset(name: 'dot.png', bytes: _png1x1),
          id: 'cmp-cache',
        );
        final WbFlowComponentCache cache = WbFlowComponentCache.instance;
        expect(cache.imageFor('cmp-cache'), isNull);
        await cache.load(component);
        final ui.Image? image = cache.imageFor('cmp-cache');
        expect(image, isNotNull);
        expect(image!.width, 1);
        expect(image.height, 1);
        expect(cache.hasFailed('cmp-cache'), isFalse);
      });
    });

    test('load：坏 base64 → hasFailed 置位且不抛异常', () async {
      const WbFlowComponent bad = WbFlowComponent(
        id: 'cmp-bad',
        name: '坏数据',
        mime: WbFlowComponent.mimePng,
        data: '!!!not-base64!!!',
      );
      final WbFlowComponentCache cache = WbFlowComponentCache.instance;
      await cache.load(bad);
      expect(cache.imageFor('cmp-bad'), isNull);
      expect(cache.hasFailed('cmp-bad'), isTrue);
      // request 对已失败条目直接跳过（不重复触发）。
      cache.request(bad);
      expect(cache.imageFor('cmp-bad'), isNull);
    });
  });
}
