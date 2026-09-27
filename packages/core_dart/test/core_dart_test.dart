import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core.dart';

void main() {
  group('WbJsonCodec', () {
    test('encode/decode 往返', () {
      const Map<String, dynamic> data = <String, dynamic>{
        'a': 1,
        'b': 'x',
        'c': <int>[1, 2],
      };
      expect(WbJsonCodec.decode(WbJsonCodec.encode(data)), data);
    });

    test('decode 非对象抛 WbCoreException', () {
      expect(
        () => WbJsonCodec.decode('[1,2]'),
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'InvalidJson')),
      );
    });

    test('tryDecode 宽容非法输入', () {
      expect(WbJsonCodec.tryDecode('not json'), isNull);
      expect(WbJsonCodec.tryDecode(''), isNull);
      expect(WbJsonCodec.tryDecode(null), isNull);
      expect(WbJsonCodec.tryDecode('{"k":1}'), <String, dynamic>{'k': 1});
    });

    test('extractList 宽容非列表', () {
      expect(WbJsonCodec.extractList(null), isEmpty);
      expect(WbJsonCodec.extractList('x'), isEmpty);
      expect(
        WbJsonCodec.extractList(<dynamic>[
          <String, dynamic>{'id': 'a'},
          'skip',
        ]),
        hasLength(1),
      );
    });

    test('unwrap 解包外包对象', () {
      final Map<String, dynamic> wrapped = <String, dynamic>{
        'page': <String, dynamic>{'id': 'p1'},
      };
      expect(WbJsonCodec.unwrap(wrapped, 'page')['id'], 'p1');
      expect(WbJsonCodec.unwrap(<String, dynamic>{'x': 1}, 'page')['x'], 1);
    });
  });

  group('WbResponse', () {
    test('解析成功信封', () {
      final WbResponse response =
          WbResponse.parse('{"ok":true,"result":{"handle":7}}');
      expect(response.ok, isTrue);
      expect(response.requireResult()['handle'], 7);
    });

    test('解析错误信封并抛出', () {
      final WbResponse response = WbResponse.parse(
        '{"ok":false,"error":{"code":"NotFound","message":"unknown board"}}',
      );
      expect(response.ok, isFalse);
      expect(response.code, 'NotFound');
      expect(
        response.requireResult,
        throwsA(isA<WbCoreException>()
            .having((WbCoreException e) => e.code, 'code', 'NotFound')
            .having((WbCoreException e) => e.message, 'message', 'unknown board')),
      );
    });

    test('非信封结构按成功对象处理', () {
      final WbResponse response =
          WbResponse.parse('{"id":"board-1","name":"n"}');
      expect(response.ok, isTrue);
      expect(response.requireResult()['id'], 'board-1');
    });

    test('非法 JSON 信封返回 InvalidJson', () {
      final WbResponse response = WbResponse.parse('<<bad>>');
      expect(response.ok, isFalse);
      expect(response.code, 'InvalidJson');
    });

    test('listAt 提取列表', () {
      final WbResponse response = WbResponse.parse(
        '{"ok":true,"result":{"pages":[{"id":"p1"},{"id":"p2"}]}}',
      );
      expect(response.listAt('pages'), hasLength(2));
      expect(response.listAt('missing'), isEmpty);
    });
  });

  group('WbBinaryCodec', () {
    test('协议头编码/解码往返', () {
      final Uint8List bytes = WbBinaryCodec.encodeHeader(
        magic: WbBinaryCodec.defaultMagic,
        version: 3,
        type: 5,
        size: 128,
        flags: 1,
      );
      expect(bytes.length, WbBinaryCodec.headerSize);
      final WbBinaryHeader header = WbBinaryCodec.decodeHeader(bytes);
      expect(header.magic, WbBinaryCodec.defaultMagic);
      expect(header.version, 3);
      expect(header.type, 5);
      expect(header.size, 128);
      expect(header.flags, 1);
    });

    test('魔数不匹配抛 FormatException', () {
      final Uint8List bytes = WbBinaryCodec.encodeHeader(
        magic: 0xDEADBEEF,
        version: 1,
        type: 0,
        size: 0,
        flags: 0,
      );
      expect(() => WbBinaryCodec.decodeHeader(bytes), throwsFormatException);
    });

    test('字节不足抛 FormatException', () {
      expect(
        () => WbBinaryCodec.decodeHeader(Uint8List(8)),
        throwsFormatException,
      );
    });

    test('整帧编码/解码往返', () {
      final Uint8List payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      final Uint8List frame = WbBinaryCodec.encodeFrame(
        type: 2,
        payload: payload,
      );
      expect(frame.length, WbBinaryCodec.headerSize + payload.length);
      final (WbBinaryHeader header, Uint8List body) =
          WbBinaryCodec.decodeFrame(frame);
      expect(header.type, 2);
      expect(header.size, payload.length);
      expect(body, payload);
    });
  });

  group('WbHandleManager', () {
    test('注册 / 取回 / 注销', () {
      final WbHandleManager manager = WbHandleManager();
      final WbHandle handle = manager.register('ctx');
      expect(handle.isValid, isTrue);
      expect(manager.get<String>(handle), 'ctx');
      expect(manager.contains(handle), isTrue);
      expect(manager.length, 1);
      expect(manager.unregister(handle), isTrue);
      expect(manager.contains(handle), isFalse);
      expect(manager.unregister(handle), isFalse);
    });

    test('invalid 句柄与类型不匹配', () {
      expect(WbHandle.invalid.isValid, isFalse);
      final WbHandleManager manager = WbHandleManager();
      final WbHandle handle = manager.register(42);
      expect(manager.get<String>(handle), isNull);
      expect(manager.get<int>(handle), 42);
      manager.clear();
      expect(manager.length, 0);
    });
  });

  group('models', () {
    test('WbPage 宽容解析', () {
      final WbPage page = WbPage.fromJson(<String, dynamic>{
        'id': 'page-1',
        'name': '页面 1',
        'locked': true,
        'background': <String, dynamic>{'preset': 'dot'},
        'elementCount': 3,
      });
      expect(page.id, 'page-1');
      expect(page.locked, isTrue);
      expect(page.hidden, isFalse);
      expect(page.background['preset'], 'dot');
      expect(page.elementCount, 3);
      expect(WbPage.fromJson(<String, dynamic>{}).id, '');
    });

    test('WbElement 解析 position/size 与 raw 透传', () {
      final WbElement element = WbElement.fromJson(<String, dynamic>{
        'id': 'el-1',
        'type': 'note',
        'position': <String, dynamic>{'x': 10.5, 'y': 20},
        'size': <String, dynamic>{'width': 200, 'height': 120},
        'zIndex': 2,
        'content': 'hi',
      });
      expect(element.x, 10.5);
      expect(element.y, 20);
      expect(element.width, 200);
      expect(element.height, 120);
      expect(element['content'], 'hi');
      expect(element.zIndex, 2);
      expect(element.visible, isTrue);
    });

    test('WbBoard 解析 pages', () {
      final WbBoard board = WbBoard.fromJson(<String, dynamic>{
        'id': 'board-1',
        'handle': 1,
        'name': '未命名白板',
        'pages': <dynamic>[
          <String, dynamic>{'id': 'page-1', 'name': '页面 1'},
        ],
      });
      expect(board.handle, 1);
      expect(board.pages, hasLength(1));
      expect(board.pageCount, 1);
      expect(board.pages.first.id, 'page-1');
    });

    test('WbTool.listFromJson 与 WbToolSchema', () {
      final List<WbTool> tools = WbTool.listFromJson(<dynamic>[
        <String, dynamic>{'id': 'edit.pen', 'name': '画笔', 'category': 'edit'},
      ]);
      expect(tools, hasLength(1));
      expect(tools.first.id, 'edit.pen');
      final WbToolSchema schema = WbToolSchema.fromJson(<String, dynamic>{
        'id': 'edit.pen',
        'name': '画笔',
        'argsSchema': <String, dynamic>{'type': 'object'},
      });
      expect(schema.tool.id, 'edit.pen');
      expect(schema.argsSchema['type'], 'object');
      expect(schema.encodeSchema(), contains('object'));
    });

    test('WbThemeSpec colorOf', () {
      final WbThemeSpec spec = WbThemeSpec.fromJson(<String, dynamic>{
        'id': 'dark-night',
        'name': '暗夜',
        'dark': true,
        'colors': <String, dynamic>{'primary': '#4C88FF'},
      });
      expect(spec.dark, isTrue);
      expect(spec.colorOf('primary'), '#4C88FF');
      expect(spec.colorOf('missing'), isNull);
    });
  });

  group('background presets', () {
    test('11 个内置预设且 id 唯一', () {
      const List<WbBackgroundPreset> presets =
          WbBackgroundService.builtinPresets;
      expect(presets, hasLength(11));
      expect(
        presets.map((WbBackgroundPreset p) => p.id).toSet(),
        hasLength(11),
      );
      expect(presets.first.id, 'whiteboard');
      expect(
        presets.where((WbBackgroundPreset p) => p.dark).map(
              (WbBackgroundPreset p) => p.id,
            ),
        unorderedEquals(<String>['blackboard', 'greenboard', 'dark-dot', 'dark-grid']),
      );
    });

    test('presetById 查找与 toBackgroundJson 形状', () {
      final WbBackgroundPreset dot =
          WbBackgroundService.presetById('dot')!;
      expect(dot.spacing, 20);
      expect(dot.lineColor, '#D0D5DD');
      final Map<String, dynamic> json = dot.toBackgroundJson();
      expect(json['id'], 'dot');
      expect(json['pattern'], 'dot');
      expect(json['baseColor'], '#FFFFFF');
      expect(json['patternColor'], '#D0D5DD');
      expect(json['preset'], 'dot');
      expect(WbBackgroundService.presetById('nope'), isNull);
    });
  });

  group('native smoke (wb_core.dll)', () {
    final String dllPath = _findWbCoreDll();
    final bool available = dllPath.isNotEmpty;

    test('init / version / board / theme 冒烟', () {
      final WbCoreFfi ffi = WbCoreFfi.load(overridePath: dllPath);
      expect(ffi.init(), 0);
      expect(ffi.versionString(), '1.0.0');

      // 白板生命周期。
      final WbBoardService boards = WbBoardService(ffi);
      final int handle = boards.create(name: 'FFI 冒烟画板');
      expect(handle, greaterThan(0));
      final WbBoard board = boards.get(handle);
      expect(board.name, 'FFI 冒烟画板');
      expect(board.pages, isNotEmpty);

      // 页面列表。
      final WbPageService pages = WbPageService(ffi);
      final List<WbPage> pageList = pages.list(board.id);
      expect(pageList, isNotEmpty);

      // 背景预设（客户端解析 → page 域写入）。
      final WbBackgroundService backgrounds = WbBackgroundService(ffi, pages);
      final Map<String, dynamic> applied =
          backgrounds.setPreset(pageList.first.id, 'dot');
      final Map<String, dynamic> background =
          Map<String, dynamic>.from(applied['background'] as Map);
      expect(background['preset'], 'dot');
      expect(background['pattern'], 'dot');

      // 主题域。
      final WbThemeService themes = WbThemeService(ffi);
      expect(themes.list(), hasLength(9));
      final WbThemeSpec dark = themes.applyById('dark-night');
      expect(dark.id, 'dark-night');
      expect(dark.dark, isTrue);
      expect(dark.colorOf('primary'), '#4C88FF');
      expect(themes.current().id, 'dark-night');

      // 工具域。
      final WbToolService tools = WbToolService(ffi);
      expect(tools.list(), isNotEmpty);

      boards.destroy(handle);
      ffi.shutdown();
    }, skip: available ? false : 'wb_core.dll 不存在，跳过原生冒烟');
  });
}

/// 在构建产物目录中寻找 wb_core.dll（找不到返回空串，触发测试跳过）。
String _findWbCoreDll() {
  if (!Platform.isWindows) {
    return '';
  }
  const List<String> candidates = <String>[
    r'e:\code\whiteboard\build\windows-x64\bin\Release\wb_core.dll',
    r'e:\code\whiteboard\build\windows-x64\bin\Debug\wb_core.dll',
  ];
  for (final String path in candidates) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  return '';
}
