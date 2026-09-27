/// Linux 平台插件 Dart 层测试：库缺失降级、加速键解析与菜单协议。
///
/// 本机（Windows）运行 `flutter test` 时不存在 `libwhiteboard_linux.so`，
/// 恰好覆盖「原生库缺失」降级路径（方法 no-op、查询 false/null、
/// 事件流为空、绝不抛异常）；FFI 正常调用路径依赖 Linux 集成环境
/// （X11 / XWayland / Wayland）另行验证。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_linux/whiteboard_linux.dart';

void main() {
  group('WbNativeLibrary', () {
    test('候选库名与构建产物命名一致', () {
      expect(wbLinuxLibraryCandidates, <String>[
        'libwhiteboard_linux.so',
        'libwhiteboard_linux_plugin.so',
      ]);
    });

    test('非 Linux 平台 tryLoad 返回 null（不抛异常）', () {
      // 本机为 Windows：Platform.isLinux 为 false → null。
      expect(WbNativeLibrary.tryLoad(), isNull);
    });

    test('overridePath 不存在时返回 null（不抛异常）', () {
      expect(
        WbNativeLibrary.tryLoad(
          overridePath: 'libwb_nonexistent_test_9f3a2b.so',
        ),
        isNull,
      );
    });

    test('注入存在但缺符号的动态库：查询同样静默降级', () async {
      DynamicLibrary? host;
      try {
        host = DynamicLibrary.executable();
      } catch (_) {
        // 宿主可执行文件不可打开：与库缺失路径等价，直接跳过。
        return;
      }
      final WbNativeLibrary library = WbNativeLibrary.fromDynamicLibrary(host);
      final LinuxWindowPlugin plugin = LinuxWindowPlugin(library: library);
      // wb_linux_window_* 符号在宿主中不存在 → 绑定整体为 null → no-op。
      await expectLater(plugin.setTransparent(true), completes);
      await expectLater(plugin.setSize(100, 100), completes);
    });
  });

  group('WbStatus', () {
    test('状态码与 C 头 window_plugin.h 一致', () {
      expect(WbStatus.ok, 0);
      expect(WbStatus.unsupported, 1);
      expect(WbStatus.failed, 2);
    });
  });

  group('LinuxWindowPlugin 库缺失降级', () {
    test('六个窗口方法全部静默完成（不抛异常）', () async {
      final LinuxWindowPlugin plugin = LinuxWindowPlugin();
      await expectLater(plugin.setTransparent(true), completes);
      await expectLater(plugin.setTransparent(false), completes);
      await expectLater(plugin.setAlwaysOnTop(true), completes);
      await expectLater(plugin.setIgnoreMouseEvents(true), completes);
      await expectLater(
        plugin.setIgnoreMouseEvents(true, forward: true),
        completes,
      );
      await expectLater(plugin.setIgnoreMouseEvents(false), completes);
      await expectLater(plugin.setFullscreen(true), completes);
      await expectLater(plugin.setFullscreen(false), completes);
      await expectLater(plugin.setPosition(120, 80), completes);
      await expectLater(plugin.setPosition(-1920, 0), completes);
      await expectLater(plugin.setSize(1440, 900), completes);
    });
  });

  group('LinuxShortcutPlugin 库缺失降级', () {
    test('注册 / 注销静默完成，触发流保持为空', () async {
      final LinuxShortcutPlugin plugin = LinuxShortcutPlugin();
      final List<String> received = <String>[];
      final StreamSubscription<String> subscription =
          plugin.onTriggered.listen(received.add);

      await expectLater(
        plugin.register('Ctrl+Shift+J', 'mode.pen'),
        completes,
      );
      await expectLater(plugin.unregister('mode.pen'), completes);
      await expectLater(plugin.unregisterAll(), completes);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(received, isEmpty);
      await subscription.cancel();
      await plugin.dispose();
    });

    test('dispose 关闭触发流且可重复调用', () async {
      final LinuxShortcutPlugin plugin = LinuxShortcutPlugin();
      final Future<void> done = expectLater(plugin.onTriggered, emitsDone);
      await plugin.dispose();
      await done;
      await plugin.dispose();
    });
  });

  group('LinuxTrayPlugin 库缺失降级', () {
    test('图标 / 提示 / 菜单调用静默完成，点击流保持为空', () async {
      final LinuxTrayPlugin plugin = LinuxTrayPlugin();
      final List<String> clicked = <String>[];
      final StreamSubscription<String> subscription =
          plugin.onMenuItemClicked.listen(clicked.add);

      await expectLater(plugin.setIcon('whiteboard'), completes);
      await expectLater(plugin.setIcon('/usr/share/icons/wb.png'), completes);
      await expectLater(plugin.setTooltip('Whiteboard'), completes);
      await expectLater(
        plugin.setMenu(const <WbTrayMenuItem>[
          WbTrayMenuItem(id: 'show', label: '显示主窗口'),
          WbTrayMenuItem(id: 'sep1', type: WbTrayMenuItemType.separator),
          WbTrayMenuItem(
            id: 'transparent',
            label: '透明批注模式',
            type: WbTrayMenuItemType.checkbox,
            checked: true,
          ),
        ]),
        completes,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(clicked, isEmpty);
      await subscription.cancel();
      await plugin.dispose();
    });

    test('dispose 关闭点击流', () async {
      final LinuxTrayPlugin plugin = LinuxTrayPlugin();
      final Future<void> done =
          expectLater(plugin.onMenuItemClicked, emitsDone);
      await plugin.dispose();
      await done;
    });
  });

  group('LinuxScreenCapturePlugin 库缺失降级', () {
    test('captureDisplay 返回 null、isAvailable 返回 false', () async {
      final LinuxScreenCapturePlugin plugin = LinuxScreenCapturePlugin();
      expect(await plugin.captureDisplay(), isNull);
      expect(await plugin.captureDisplay(displayId: 0), isNull);
      expect(await plugin.captureDisplay(displayId: 2), isNull);
      expect(await plugin.isAvailable(), isFalse);
    });
  });

  group('WbCaptureFrame', () {
    test('fromMap 解析完整字段', () {
      final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final WbCaptureFrame frame = WbCaptureFrame.fromMap(<Object?, Object?>{
        'bytes': bytes,
        'width': 1,
        'height': 1,
        'stride': 4,
      });
      expect(frame.bytes, same(bytes));
      expect(frame.width, 1);
      expect(frame.height, 1);
      expect(frame.stride, 4);
    });

    test('fromMap 字段缺失 / 类型不符时返回空帧（不抛异常）', () {
      final WbCaptureFrame frame = WbCaptureFrame.fromMap(<Object?, Object?>{
        'width': '2',
      });
      expect(frame.bytes, isEmpty);
      expect(frame.width, 0);
      expect(frame.height, 0);
      expect(frame.stride, 0);
    });
  });

  group('WbAccelerator.parse 表驱动', () {
    test('合法输入：别名归一与大小写', () {
      const Map<String, String> cases = <String, String>{
        'Ctrl+Shift+J': 'Ctrl+Shift+J',
        'ctrl+shift+j': 'Ctrl+Shift+J',
        'Control + Shift + J': 'Ctrl+Shift+J',
        'Cmd+Space': 'Super+Space',
        'command+space': 'Super+Space',
        'Win+Space': 'Super+Space',
        'Super+Q': 'Super+Q',
        'meta+q': 'Super+Q',
        '⌘+Space': 'Super+Space',
        'Alt+F4': 'Alt+F4',
        'Option+F4': 'Alt+F4',
        'opt+F4': 'Alt+F4',
        'F12': 'F12',
        'f24': 'F24',
        'Escape': 'Escape',
        'ESC': 'Escape',
        'Enter': 'Return',
        'Return': 'Return',
        'Space': 'Space',
        'Tab': 'Tab',
        'Backspace': 'Backspace',
        'Delete': 'Delete',
        'Del': 'Delete',
        'Insert': 'Insert',
        'Home': 'Home',
        'End': 'End',
        'PageUp': 'PageUp',
        'pgup': 'PageUp',
        'PageDown': 'PageDown',
        'ArrowLeft': 'Left',
        'ArrowRight': 'Right',
        'ArrowUp': 'Up',
        'ArrowDown': 'Down',
        'Ctrl+0': 'Ctrl+0',
      };
      cases.forEach((String input, String expected) {
        final WbAccelerator? accelerator = WbAccelerator.parse(input);
        expect(accelerator, isNotNull, reason: '应可解析: "$input"');
        expect(accelerator!.toString(), expected, reason: '输入: "$input"');
      });
    });

    test('非法输入返回 null（不抛异常）', () {
      const List<String> invalid = <String>[
        '',
        '   ',
        '+',
        'Ctrl+',
        '+J',
        'Ctrl+Shift+',
        'Ctrl+Ctrl+J',
        'Ctrl+J+K',
        'Ctrl+F0',
        'Ctrl+F25',
        'Ctrl+F100',
        'Ctrl+Ä',
        '请按Ctrl键',
        'Shift+Shift+A',
        'Ctrl+Alt+Ctrl+A',
        'Cntrl+J',
      ];
      for (final String input in invalid) {
        expect(
          WbAccelerator.parse(input),
          isNull,
          reason: '应非法: "$input"',
        );
      }
    });

    test('修饰键组合精确解析', () {
      final WbAccelerator? accelerator =
          WbAccelerator.parse('Ctrl+Alt+Shift+Super+K');
      expect(accelerator, isNotNull);
      expect(accelerator!.ctrl, isTrue);
      expect(accelerator.shift, isTrue);
      expect(accelerator.alt, isTrue);
      expect(accelerator.superKey, isTrue);
      expect(accelerator.key, 'K');

      final WbAccelerator? plain = WbAccelerator.parse('J');
      expect(plain, isNotNull);
      expect(plain!.ctrl, isFalse);
      expect(plain.shift, isFalse);
      expect(plain.alt, isFalse);
      expect(plain.superKey, isFalse);
      expect(plain.key, 'J');
    });
  });

  group('WbTrayMenuItem 序列化协议', () {
    test('toMap 字段与 C 侧 JSON 协议一致', () {
      const WbTrayMenuItem item = WbTrayMenuItem(
        id: 'view.toggle',
        label: '显示面板',
        type: WbTrayMenuItemType.checkbox,
        enabled: false,
        checked: true,
      );
      expect(item.toMap(), <String, Object?>{
        'id': 'view.toggle',
        'label': '显示面板',
        'type': 'checkbox',
        'enabled': false,
        'checked': true,
      });
    });

    test('菜单整体 jsonEncode（字段顺序固定，原生 json-glib 消费）', () {
      const List<WbTrayMenuItem> items = <WbTrayMenuItem>[
        WbTrayMenuItem(id: 'open', label: '打开'),
        WbTrayMenuItem(id: 'divider', type: WbTrayMenuItemType.separator),
        WbTrayMenuItem(
          id: 'auto',
          label: '自动纠错',
          type: WbTrayMenuItemType.checkbox,
          checked: true,
        ),
      ];
      final String encoded = jsonEncode(
        items
            .map((WbTrayMenuItem item) => item.toMap())
            .toList(growable: false),
      );
      expect(
        encoded,
        '[{"id":"open","label":"打开","type":"normal","enabled":true,'
        '"checked":false},{"id":"divider","label":"","type":"separator",'
        '"enabled":true,"checked":false},{"id":"auto","label":"自动纠错",'
        '"type":"checkbox","enabled":true,"checked":true}]',
      );
    });

    test('默认构造形态（normal / enabled / checked）', () {
      const WbTrayMenuItem item = WbTrayMenuItem(id: 'quit', label: '退出');
      expect(item.type, WbTrayMenuItemType.normal);
      expect(item.enabled, isTrue);
      expect(item.checked, isFalse);
    });
  });
}
