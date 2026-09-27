/// 透明覆盖层服务（C2 / 问题 7）测试：状态机 / 平台窗口调用序列 /
/// 穿透同步 / 几何还原 / 无插件环境静默降级。
///
/// 平台通道 `whiteboard/windows` 用 mock 记录调用；未注册 mock 的场景
/// 验证降级路径（MissingPluginException 被服务内部静默吸收）。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/platform/transparent_overlay_service.dart';
import 'package:whiteboard_desktop/services/shortcut_service.dart';
import 'package:whiteboard_desktop/widgets/annotation/annotation_controller.dart';

/// 记录 `whiteboard/windows` 通道调用的替身（模拟原生插件已注册）。
class _ChannelRecorder {
  static const MethodChannel channel = MethodChannel('whiteboard/windows');

  final List<MethodCall> calls = <MethodCall>[];

  void install({Object? Function(MethodCall call)? onCall}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      return onCall?.call(call);
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  }

  /// 按顺序记录的方法名。
  List<String> get methods => <String>[
        for (final MethodCall call in calls) call.method,
      ];

  /// 指定方法的调用次数。
  int countOf(String method) =>
      calls.where((MethodCall call) => call.method == method).length;

  /// 指定方法最后一次调用的参数。
  Map<String, Object?> lastArgsOf(String method) {
    final MethodCall call =
        calls.lastWhere((MethodCall call) => call.method == method);
    return (call.arguments as Map<Object?, Object?>).cast<String, Object?>();
  }
}

/// 窗口几何替身（确定性边界；真实实现经 window_manager 在测试环境降级）。
class _FakeGeometry implements WbOverlayWindowGeometry {
  _FakeGeometry({this.next});

  /// [read] 的返回值。
  WbWindowBounds? next;

  /// 最近一次 [restore] 的入参。
  WbWindowBounds? restored;

  @override
  Future<WbWindowBounds?> read() async => next;

  @override
  Future<void> restore(WbWindowBounds bounds) async {
    restored = bounds;
  }
}

/// 永不注册（返回 null）的热键注册器。
Future<WbAnnotationHotkey?> _noHotkey(
  WbShortcut shortcut,
  VoidCallback onTrigger,
) async =>
    null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WbTransparentOverlayService 状态机', () {
    test('enter：记录 bounds → 全屏 → 透明 → 置顶（幂等）', () async {
      final _ChannelRecorder recorder = _ChannelRecorder()..install();
      final _FakeGeometry geometry = _FakeGeometry(
        next: const WbWindowBounds(left: 20, top: 30, width: 1280, height: 800),
      );
      final WbTransparentOverlayService service =
          WbTransparentOverlayService(geometry: geometry);
      addTearDown(service.dispose);

      await service.enter();
      expect(service.phase, WbOverlayPhase.active);
      expect(service.isActive, isTrue);
      expect(service.isPenetrating, isFalse);
      expect(service.savedBounds, geometry.next);
      // mock 通道返回 null → 「仅原生明确返回 true 才算成功」→ false。
      expect(service.isTransparentApplied, isFalse);
      expect(
        recorder.methods,
        <String>[
          'window.setFullscreen',
          'window.setTransparent',
          'window.setAlwaysOnTop',
        ],
      );
      expect(recorder.lastArgsOf('window.setAlwaysOnTop')['onTop'], isTrue);
      expect(recorder.lastArgsOf('window.setTransparent')['transparent'], isTrue);
      expect(recorder.lastArgsOf('window.setFullscreen')['fullscreen'], isTrue);

      // 幂等：重复 enter 不再触碰平台。
      await service.enter();
      expect(recorder.countOf('window.setAlwaysOnTop'), 1);
      expect(recorder.countOf('window.setFullscreen'), 1);
    });

    test('exit：还原穿透 / 全屏 / 透明 / 置顶 / bounds（幂等）', () async {
      final _ChannelRecorder recorder = _ChannelRecorder()..install();
      final _FakeGeometry geometry = _FakeGeometry(
        next: const WbWindowBounds(left: 20, top: 30, width: 1280, height: 800),
      );
      final WbTransparentOverlayService service =
          WbTransparentOverlayService(geometry: geometry);
      addTearDown(service.dispose);

      await service.enter();
      await service.setPenetrate(true);
      recorder.calls.clear();

      await service.exit();
      expect(service.phase, WbOverlayPhase.off);
      expect(service.isActive, isFalse);
      expect(service.isPenetrating, isFalse);
      expect(service.isTransparentApplied, isFalse);
      expect(service.savedBounds, isNull);
      expect(
        recorder.methods,
        <String>[
          'window.setIgnoreMouseEvents',
          'window.setFullscreen',
          'window.setTransparent',
          'window.setAlwaysOnTop',
        ],
      );
      expect(
        recorder.lastArgsOf('window.setIgnoreMouseEvents')['ignore'],
        isFalse,
      );
      expect(recorder.lastArgsOf('window.setFullscreen')['fullscreen'], isFalse);
      expect(recorder.lastArgsOf('window.setTransparent')['transparent'], isFalse);
      expect(recorder.lastArgsOf('window.setAlwaysOnTop')['onTop'], isFalse);
      expect(geometry.restored, geometry.next);

      // 幂等：重复 exit 不再触碰平台。
      await service.exit();
      expect(recorder.countOf('window.setFullscreen'), 1);
    });

    test('toggle 在 enter / exit 间切换', () async {
      _ChannelRecorder().install();
      final WbTransparentOverlayService service = WbTransparentOverlayService(
        geometry: _FakeGeometry(),
      );
      addTearDown(service.dispose);

      await service.toggle();
      expect(service.isActive, isTrue);
      await service.toggle();
      expect(service.isActive, isFalse);
    });

    test('真透明成功（原生返回 true）：isTransparentApplied 置位，exit 复位', () async {
      final _ChannelRecorder recorder = _ChannelRecorder()
        ..install(
          onCall: (MethodCall call) =>
              call.method == 'window.setTransparent' ? true : null,
        );
      final WbTransparentOverlayService service = WbTransparentOverlayService(
        geometry: _FakeGeometry(),
      );
      addTearDown(service.dispose);

      await service.enter();
      expect(service.isTransparentApplied, isTrue);
      expect(recorder.countOf('window.setTransparent'), 1);

      await service.exit();
      expect(service.isTransparentApplied, isFalse);
    });

    test('真透明失败（原生返回 null）：isTransparentApplied 保持 false', () async {
      _ChannelRecorder().install();
      final WbTransparentOverlayService service = WbTransparentOverlayService(
        geometry: _FakeGeometry(),
      );
      addTearDown(service.dispose);

      await service.enter();
      expect(service.isTransparentApplied, isFalse);

      await service.exit();
      expect(service.isTransparentApplied, isFalse);
    });
  });

  group('WbTransparentOverlayService 穿透同步', () {
    test('setPenetrate → setIgnoreMouseEvents（forward 保留悬停）', () async {
      final _ChannelRecorder recorder = _ChannelRecorder()..install();
      final WbTransparentOverlayService service =
          WbTransparentOverlayService(geometry: _FakeGeometry());
      addTearDown(service.dispose);

      await service.enter();
      await service.setPenetrate(true);
      expect(service.isPenetrating, isTrue);
      expect(
        recorder.lastArgsOf('window.setIgnoreMouseEvents'),
        <String, Object?>{'ignore': true, 'forward': true},
      );

      await service.setPenetrate(false);
      expect(service.isPenetrating, isFalse);
      expect(
        recorder.lastArgsOf('window.setIgnoreMouseEvents'),
        <String, Object?>{'ignore': false, 'forward': false},
      );
    });

    test('未激活时 setPenetrate 只切换状态、不触碰平台', () async {
      final _ChannelRecorder recorder = _ChannelRecorder()..install();
      final WbTransparentOverlayService service =
          WbTransparentOverlayService(geometry: _FakeGeometry());
      addTearDown(service.dispose);

      await service.setPenetrate(true);
      expect(service.isPenetrating, isTrue);
      expect(recorder.countOf('window.setIgnoreMouseEvents'), 0);
    });
  });

  group('无插件环境静默降级', () {
    test('默认几何（window_manager）读取失败时降级为 null', () async {
      const WbWindowManagerGeometry geometry = WbWindowManagerGeometry();
      final WbWindowBounds? bounds = await geometry.read();
      expect(bounds, isNull);
      await geometry.restore(
        const WbWindowBounds(left: 0, top: 0, width: 800, height: 600),
      );
    });

    test('未注册通道：enter / setPenetrate / exit 不抛异常且状态正确', () async {
      // 不安装 mock：WindowsWindowPlugin 内部捕获 MissingPluginException。
      final WbTransparentOverlayService service = WbTransparentOverlayService(
        geometry: _FakeGeometry(
          next: const WbWindowBounds(left: 0, top: 0, width: 800, height: 600),
        ),
      );
      addTearDown(service.dispose);

      await service.enter();
      expect(service.isActive, isTrue);
      await service.setPenetrate(true);
      expect(service.isPenetrating, isTrue);
      await service.exit();
      expect(service.phase, WbOverlayPhase.off);
    });
  });

  group('批注控制器 → 覆盖层服务联动', () {
    test('enter 后切换穿透：通道收到窗口级 setIgnoreMouseEvents', () async {
      final _ChannelRecorder recorder = _ChannelRecorder()..install();
      final WbTransparentOverlayService service =
          WbTransparentOverlayService(geometry: _FakeGeometry());
      final WbAnnotationController controller = WbAnnotationController(
        overlay: service,
        hotkeyRegistrar: _noHotkey,
      );
      addTearDown(() {
        controller.dispose();
        service.dispose();
      });

      await controller.enter();
      expect(recorder.countOf('window.setIgnoreMouseEvents'), 0);

      await controller.setPenetrate(true);
      expect(
        recorder.lastArgsOf('window.setIgnoreMouseEvents'),
        <String, Object?>{'ignore': true, 'forward': true},
      );

      await controller.setPenetrate(false);
      expect(
        recorder.lastArgsOf('window.setIgnoreMouseEvents'),
        <String, Object?>{'ignore': false, 'forward': false},
      );
    });
  });
}
