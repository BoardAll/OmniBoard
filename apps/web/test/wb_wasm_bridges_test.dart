/// Web 引擎桥适配器测试（`WbWasmPageOps` / `WbWasmCanvasEngine`）。
///
/// 覆盖延迟注入状态机（未绑定 → 绑定 → 解绑）与调用转发形状：
/// 记录 fake 引擎调用器（[WbEngineCaller]），断言适配器把共享包接口
/// （`WbPageOps` / `WbCanvasEngine`）的方法转发为正确的 `wb_*` 调用，
/// 并正确解析域服务返回（页面 / 元素 / 缩略图 base64）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core_common.dart';
import 'package:whiteboard_web/services/wb_wasm_bridges.dart';

/// 记录调用并返回预设信封的引擎调用器 fake。
///
/// 记录格式：`fn::参数`（字符串参数按顺序追加）、`fn#整数`（整数参数）、
/// 组合形状如 `wb_page_move::p9#2`、`wb_render_thumbnail::p1#200#125`。
class _RecordingCaller implements WbEngineCaller {
  /// 记录到的调用串（按调用顺序）。
  final List<String> calls = <String>[];

  /// 按函数名返回的响应信封（缺省 `{"ok":true,"result":{}}`）。
  final Map<String, String> responses = <String, String>{};

  String _respond(String fn) => responses[fn] ?? '{"ok":true,"result":{}}';

  @override
  int init([String configJson = '']) => 0;

  @override
  void shutdown() {}

  @override
  String versionString() => 'test';

  @override
  String call0(String fn) {
    calls.add(fn);
    return _respond(fn);
  }

  @override
  String call1(String fn, String a) {
    calls.add('$fn::$a');
    return _respond(fn);
  }

  @override
  String call2(String fn, String a, String b) {
    calls.add('$fn::$a::$b');
    return _respond(fn);
  }

  @override
  String call3(String fn, String a, String b, String c) {
    calls.add('$fn::$a::$b::$c');
    return _respond(fn);
  }

  @override
  String callInt(String fn, int value) {
    calls.add('$fn#$value');
    return _respond(fn);
  }

  @override
  String call1Int(String fn, String a, int value) {
    calls.add('$fn::$a#$value');
    return _respond(fn);
  }

  @override
  String call1Int2(String fn, String a, int x, int y) {
    calls.add('$fn::$a#$x#$y');
    return _respond(fn);
  }

  @override
  String call1Int1(String fn, String a, int value, String b) {
    calls.add('$fn::$a#$value::$b');
    return _respond(fn);
  }

  @override
  String call1Float2(String fn, String a, double x, double y) {
    calls.add('$fn::$a#$x#$y');
    return _respond(fn);
  }

  @override
  String callFloat3(String fn, double x, double y, double z) {
    calls.add('$fn#$x#$y#$z');
    return _respond(fn);
  }

  @override
  String callHandle(String fn, int handle) {
    calls.add('$fn#$handle');
    return _respond(fn);
  }

  @override
  String callHandle1(String fn, int handle, String a) {
    calls.add('$fn#$handle::$a');
    return _respond(fn);
  }

  @override
  String callHandleInt(String fn, int handle, int value) {
    calls.add('$fn#$handle#$value');
    return _respond(fn);
  }

  @override
  String callHandle1Int2(String fn, int handle, String a, int x, int y) {
    calls.add('$fn#$handle::$a#$x#$y');
    return _respond(fn);
  }

  @override
  int callU64(String fn, String a) {
    calls.add('$fn::$a');
    return 0;
  }

  @override
  void callVoidHandle(String fn, int handle) {
    calls.add('$fn#$handle');
  }
}

void main() {
  group('WbWasmPageOps（页面桥）', () {
    test('未绑定时 isAvailable=false，全部方法抛 StateError', () {
      final WbWasmPageOps ops = WbWasmPageOps();

      expect(ops.isAvailable, isFalse);
      expect(() => ops.create('b1'), throwsStateError);
      expect(() => ops.rename('p1', '新名'), throwsStateError);
      expect(() => ops.delete('p1'), throwsStateError);
      expect(() => ops.duplicate('p1'), throwsStateError);
      expect(() => ops.move('p1', 1), throwsStateError);
      expect(() => ops.lock('p1', true), throwsStateError);
      expect(() => ops.hide('p1', true), throwsStateError);
      expect(() => ops.setBackground('p1', const <String, dynamic>{}),
          throwsStateError);
    });

    test('绑定后转发 WASM 页服务并解析结果', () {
      final _RecordingCaller caller = _RecordingCaller()
        ..responses['wb_page_create'] =
            '{"ok":true,"result":{"page":{"id":"p1","name":"页面 1"}}}'
        ..responses['wb_page_rename'] =
            '{"ok":true,"result":{"page":{"id":"p1","name":"新名"}}}'
        ..responses['wb_page_duplicate'] =
            '{"ok":true,"result":{"page":{"id":"p2","name":"页面 1 副本"}}}';
      final WbWasmPageOps ops = WbWasmPageOps()..attach(WbPageService(caller));

      expect(ops.isAvailable, isTrue);

      // create：options 缺省编码为 {}，结果经 page 键解包。
      final WbPage created = ops.create('b1');
      expect(created.id, 'p1');
      expect(created.name, '页面 1');
      expect(caller.calls, contains('wb_page_create::b1::{}'));

      // rename / duplicate：返回解析后的 WbPage。
      expect(ops.rename('p1', '新名').name, '新名');
      expect(caller.calls, contains('wb_page_rename::p1::新名'));
      expect(ops.duplicate('p1').id, 'p2');
      expect(caller.calls, contains('wb_page_duplicate::p1'));

      // 行操作：delete / move / lock / hide / setBackground。
      ops.delete('p2');
      expect(caller.calls, contains('wb_page_delete::p2'));

      ops.move('p1', 2);
      expect(caller.calls, contains('wb_page_move::p1#2'));

      ops.lock('p1', true);
      expect(caller.calls, contains('wb_page_lock::p1#1'));

      ops.hide('p1', false);
      expect(caller.calls, contains('wb_page_hide::p1#0'));

      ops.setBackground('p1', const <String, dynamic>{'preset': 'grid'});
      expect(
        caller.calls,
        contains('wb_page_set_background::p1::{"preset":"grid"}'),
      );
    });

    test('detach 后回退未绑定状态', () {
      final WbWasmPageOps ops = WbWasmPageOps()
        ..attach(WbPageService(_RecordingCaller()));
      expect(ops.isAvailable, isTrue);

      ops.detach();
      expect(ops.isAvailable, isFalse);
      expect(() => ops.create('b1'), throwsStateError);
    });
  });

  group('WbWasmCanvasEngine（画布引擎桥）', () {
    test('未绑定时 isAvailable=false，全部方法抛 StateError', () {
      final WbWasmCanvasEngine engine = WbWasmCanvasEngine();

      expect(engine.isAvailable, isFalse);
      expect(() => engine.listElements('p1'), throwsStateError);
      expect(
        () => engine.updateElement('e1', const <String, dynamic>{}),
        throwsStateError,
      );
      expect(() => engine.deleteElement('e1'), throwsStateError);
      expect(() => engine.thumbnail('p1', 100, 60), throwsStateError);
    });

    test('绑定后转发 WASM 元素 / 渲染服务', () {
      final _RecordingCaller caller = _RecordingCaller()
        ..responses['wb_element_list'] = '{"ok":true,"result":{"elements":'
            '[{"id":"e1","type":"shape",'
            '"position":{"x":10,"y":20},"size":{"width":100,"height":50}}]}}'
        ..responses['wb_element_update'] =
            '{"ok":true,"result":{"element":{"id":"e1"}}}';
      final Uint8List png = Uint8List.fromList(<int>[1, 2, 3, 4]);
      caller.responses['wb_render_thumbnail'] = jsonEncode(<String, dynamic>{
        'ok': true,
        'result': <String, dynamic>{'png': base64Encode(png)},
      });

      final WbWasmCanvasEngine engine = WbWasmCanvasEngine()
        ..attach(
          element: WbElementService(caller),
          render: WbRenderService(caller),
        );
      expect(engine.isAvailable, isTrue);

      // listElements：元素列表按页面转发并解析。
      final List<WbElement> elements = engine.listElements('p1');
      expect(elements, hasLength(1));
      expect(elements.single.id, 'e1');
      expect(elements.single.x, 10);
      expect(caller.calls, contains('wb_element_list::p1'));

      // 行操作：update / delete。
      engine.updateElement('e1', const <String, dynamic>{'x': 1});
      expect(caller.calls, contains('wb_element_update::e1::{"x":1}'));

      engine.deleteElement('e1');
      expect(caller.calls, contains('wb_element_delete::e1'));

      // 缩略图：base64 PNG 解码为字节。
      final Uint8List? bytes = engine.thumbnail('p1', 200, 125);
      expect(bytes, png);
      expect(caller.calls, contains('wb_render_thumbnail::p1#200#125'));
    });

    test('缩略图缺失或非法数据返回 null（回退静态预览）', () {
      final _RecordingCaller caller = _RecordingCaller();
      final WbWasmCanvasEngine engine = WbWasmCanvasEngine()
        ..attach(
          element: WbElementService(caller),
          render: WbRenderService(caller),
        );

      // 空 result：无缩略图数据。
      expect(engine.thumbnail('p1', 10, 10), isNull);

      // 非法 base64：宽容返回 null。
      caller.responses['wb_render_thumbnail'] =
          '{"ok":true,"result":{"png":"%%not-base64%%"}}';
      expect(engine.thumbnail('p1', 10, 10), isNull);
    });

    test('detach 后回退未绑定状态', () {
      final WbWasmCanvasEngine engine = WbWasmCanvasEngine()
        ..attach(
          element: WbElementService(_RecordingCaller()),
          render: WbRenderService(_RecordingCaller()),
        );
      expect(engine.isAvailable, isTrue);

      engine.detach();
      expect(engine.isAvailable, isFalse);
      expect(() => engine.listElements('p1'), throwsStateError);
    });
  });
}
