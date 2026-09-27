/// macOS 平台插件 Dart 层测试：通道调用 / 入站事件 / 降级行为。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_macos/whiteboard_macos.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('whiteboard/macos');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    log.clear();
    messenger.setMockMethodCallHandler(channel,
        (MethodCall call) async {
      log.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('MacosWindowPlugin', () {
    test('透传窗口方法到平台通道', () async {
      final MacosWindowPlugin plugin = MacosWindowPlugin();

      await plugin.setTransparent(true);
      await plugin.setAlwaysOnTop(true);
      await plugin.setIgnoreMouseEvents(true, forward: true);
      await plugin.setFullscreen(false);
      await plugin.setPosition(120, 80);
      await plugin.setSize(1440, 900);

      expect(log.map((MethodCall call) => call.method), <String>[
        'window.setTransparent',
        'window.setAlwaysOnTop',
        'window.setIgnoreMouseEvents',
        'window.setFullscreen',
        'window.setPosition',
        'window.setSize',
      ]);
      expect(log[0].arguments, <String, Object?>{'transparent': true});
      expect(
        log[2].arguments,
        <String, Object?>{'ignore': true, 'forward': true},
      );
      expect(log[4].arguments, <String, Object?>{'x': 120, 'y': 80});
      expect(log[5].arguments, <String, Object?>{'width': 1440, 'height': 900});
    });

    test('原生未注册时静默降级不抛异常', () async {
      final MacosWindowPlugin plugin = MacosWindowPlugin(
        channel: const MethodChannel('whiteboard/missing_window'),
      );
      await expectLater(plugin.setTransparent(true), completes);
      await expectLater(plugin.setIgnoreMouseEvents(true), completes);
    });
  });

  group('MacosShortcutPlugin', () {
    test('注册 / 注销透传到平台通道', () async {
      final MacosShortcutPlugin plugin = MacosShortcutPlugin();

      await plugin.register('Ctrl+Shift+J', 'mode.pen');
      await plugin.unregister('mode.pen');
      await plugin.unregisterAll();

      expect(log.map((MethodCall call) => call.method), <String>[
        'shortcut.register',
        'shortcut.unregister',
        'shortcut.unregisterAll',
      ]);
      expect(log[0].arguments, <String, Object?>{
        'accelerator': 'Ctrl+Shift+J',
        'id': 'mode.pen',
      });
      expect(log[1].arguments, <String, Object?>{'id': 'mode.pen'});

      await plugin.dispose();
    });

    test('原生触发事件进入 onTriggered 流', () async {
      final MacosShortcutPlugin plugin = MacosShortcutPlugin();
      final Future<String> triggered = plugin.onTriggered.first;

      await messenger.handlePlatformMessage(
        'whiteboard/macos',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('shortcut.triggered', <String, Object?>{
            'id': 'mode.previousTool',
          }),
        ),
        (_) {},
      );

      expect(await triggered, 'mode.previousTool');
      await plugin.dispose();
    });

    test('忽略非法触发事件（缺 id / 未知方法）', () async {
      final MacosShortcutPlugin plugin = MacosShortcutPlugin();
      final List<String> received = <String>[];
      plugin.onTriggered.listen(received.add);

      await messenger.handlePlatformMessage(
        'whiteboard/macos',
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('shortcut.triggered')),
        (_) {},
      );
      await messenger.handlePlatformMessage(
        'whiteboard/macos',
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('unknown.event')),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
      await plugin.dispose();
    });

    test('原生未注册时注册调用静默降级', () async {
      final MacosShortcutPlugin plugin = MacosShortcutPlugin(
        channel: const MethodChannel('whiteboard/missing_shortcut'),
      );
      await expectLater(plugin.register('Ctrl+Z', 'edit.undo'), completes);
      await plugin.dispose();
    });
  });

  group('MacosTrayPlugin', () {
    test('图标 / 提示 / 菜单透传', () async {
      final MacosTrayPlugin plugin = MacosTrayPlugin();

      await plugin.setIcon('assets/tray.ico');
      await plugin.setTooltip('Whiteboard');
      await plugin.setMenu(const <WbTrayMenuItem>[
        WbTrayMenuItem(id: 'show', label: '显示主窗口'),
        WbTrayMenuItem(id: 'sep1', type: WbTrayMenuItemType.separator),
        WbTrayMenuItem(
          id: 'transparent',
          label: '透明批注模式',
          type: WbTrayMenuItemType.checkbox,
          checked: true,
        ),
        WbTrayMenuItem(id: 'quit', label: '退出', enabled: false),
      ]);

      expect(log[0].method, 'tray.setIcon');
      expect(log[0].arguments, <String, Object?>{'iconPath': 'assets/tray.ico'});
      expect(log[1].method, 'tray.setTooltip');
      expect(log[1].arguments, <String, Object?>{'tooltip': 'Whiteboard'});

      expect(log[2].method, 'tray.setMenu');
      final Object? items = (log[2].arguments as Map<Object?, Object?>)['items'];
      expect(items, isA<List<Object?>>());
      final List<Object?> list = items! as List<Object?>;
      expect(list.length, 4);
      expect(list[1], <String, Object?>{
        'id': 'sep1',
        'label': '',
        'type': 'separator',
        'enabled': true,
        'checked': false,
      });
      expect((list[2]! as Map<Object?, Object?>)['checked'], true);
      expect((list[3]! as Map<Object?, Object?>)['enabled'], false);

      await plugin.dispose();
    });

    test('菜单点击事件进入 onMenuItemClicked 流', () async {
      final MacosTrayPlugin plugin = MacosTrayPlugin();
      final Future<String> clicked = plugin.onMenuItemClicked.first;

      await messenger.handlePlatformMessage(
        'whiteboard/macos',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('tray.clicked', <String, Object?>{'id': 'quit'}),
        ),
        (_) {},
      );

      expect(await clicked, 'quit');
      await plugin.dispose();
    });

    test('原生未注册时菜单设置静默降级', () async {
      final MacosTrayPlugin plugin = MacosTrayPlugin(
        channel: const MethodChannel('whiteboard/missing_tray'),
      );
      await expectLater(
        plugin.setMenu(const <WbTrayMenuItem>[
          WbTrayMenuItem(id: 'show', label: '显示'),
        ]),
        completes,
      );
      await plugin.dispose();
    });
  });

  group('MacosScreenCapturePlugin', () {
    test('解析捕获帧（bytes/width/height/stride）', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        log.add(call);
        if (call.method == 'capture.captureDisplay') {
          return <String, Object?>{
            'bytes': Uint8List.fromList(<int>[1, 2, 3, 4]),
            'width': 1,
            'height': 1,
            'stride': 4,
          };
        }
        if (call.method == 'capture.isAvailable') {
          return true;
        }
        return null;
      });

      final MacosScreenCapturePlugin plugin = MacosScreenCapturePlugin();
      final WbCaptureFrame? frame = await plugin.captureDisplay(displayId: 0);

      expect(log.single.method, 'capture.captureDisplay');
      expect(log.single.arguments, <String, Object?>{'displayId': 0});
      expect(frame, isNotNull);
      expect(frame!.width, 1);
      expect(frame.height, 1);
      expect(frame.stride, 4);
      expect(frame.bytes, <int>[1, 2, 3, 4]);
      expect(await plugin.isAvailable(), isTrue);
    });

    test('原生未注册时返回 null / false', () async {
      final MacosScreenCapturePlugin plugin = MacosScreenCapturePlugin(
        channel: const MethodChannel('whiteboard/missing_capture'),
      );
      expect(await plugin.captureDisplay(), isNull);
      expect(await plugin.isAvailable(), isFalse);
    });

    test('字段缺失时返回空帧（不抛异常）', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return <String, Object?>{'width': 2};
      });
      final MacosScreenCapturePlugin plugin = MacosScreenCapturePlugin();
      final WbCaptureFrame? frame = await plugin.captureDisplay();
      expect(frame, isNotNull);
      expect(frame!.width, 2);
      expect(frame.height, 0);
      expect(frame.bytes, isEmpty);
    });
  });
}
