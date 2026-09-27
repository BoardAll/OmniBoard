/// 桌面截图兜底背景控制器（波次 B / 问题 5）测试：激活条件 / 首帧抓取 /
/// 穿透态定时刷新 / 退出释放 / 默认 BGRA 解码 / 静默降级。
///
/// 平台通道全部替身注入（假截图插件 + 假解码器），不触发真实原生调用。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/platform/desktop_backdrop_controller.dart';
import 'package:whiteboard_windows/whiteboard_windows.dart';

/// 截图替身：按次计数返回预制帧（null 模拟不可用；可配置抛错）。
class _FakeCapture implements WbScreenCapturePlugin {
  _FakeCapture({this.frame, this.throwOnCapture = false});

  /// [captureVirtualScreen] 的返回值。
  WbCaptureFrame? frame;

  /// true 时 [captureVirtualScreen] 抛错（模拟原生失败）。
  bool throwOnCapture;

  /// 虚拟屏抓取调用次数。
  int calls = 0;

  @override
  Future<WbCaptureFrame?> captureDisplay({int displayId = -1}) async => frame;

  @override
  Future<WbCaptureFrame?> captureVirtualScreen() async {
    calls++;
    if (throwOnCapture) {
      throw StateError('capture failed');
    }
    return frame;
  }

  @override
  Future<bool> isAvailable() async => true;
}

/// 构造 BGRA 帧（像素全 0，尺寸与行距可控）。
WbCaptureFrame _frame({int width = 4, int height = 3, int? stride}) {
  final int rowBytes = width * 4;
  return WbCaptureFrame(
    bytes: Uint8List((stride ?? rowBytes) * height),
    width: width,
    height: height,
    stride: stride ?? rowBytes,
  );
}

/// 轮询等待 [predicate] 成立（超时上限约 1s；失败给出可读原因）。
Future<void> _waitFor(bool Function() predicate, {String? reason}) async {
  for (int i = 0; i < 200 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue, reason: reason ?? '条件未在时限内成立');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WbDesktopBackdropController 激活条件', () {
    test('批注激活且透明未生效：激活并抓取首帧', () async {
      final _FakeCapture capture = _FakeCapture(frame: _frame());
      final ui.Image fake = await createTestImage(
        width: 4,
        height: 3,
        cache: false,
      );
      final WbDesktopBackdropController controller =
          WbDesktopBackdropController(
        capture: capture,
        decoder: (WbCaptureFrame _) async => fake,
      );
      addTearDown(controller.dispose);

      expect(controller.isActive, isFalse);
      controller.sync(
        annotationActive: true,
        transparentApplied: false,
        penetrating: false,
      );
      expect(controller.isActive, isTrue);
      await _waitFor(() => controller.image != null);
      expect(identical(controller.image, fake), isTrue);
      expect(capture.calls, 1);
    });

    test('原生透明生效（transparentApplied=true）：不进兜底、不抓帧', () async {
      final _FakeCapture capture = _FakeCapture(frame: _frame());
      final WbDesktopBackdropController controller =
          WbDesktopBackdropController(capture: capture);
      addTearDown(controller.dispose);

      controller.sync(
        annotationActive: true,
        transparentApplied: true,
        penetrating: false,
      );
      expect(controller.isActive, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(capture.calls, 0);
      expect(controller.image, isNull);
    });

    test('未激活批注：不进兜底', () async {
      final _FakeCapture capture = _FakeCapture(frame: _frame());
      final WbDesktopBackdropController controller =
          WbDesktopBackdropController(capture: capture);
      addTearDown(controller.dispose);

      controller.sync(
        annotationActive: false,
        transparentApplied: false,
        penetrating: false,
      );
      expect(controller.isActive, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(capture.calls, 0);
    });

    test('退出（annotationActive=false）：停用并释放图片', () async {
      final _FakeCapture capture = _FakeCapture(frame: _frame());
      final ui.Image fake = await createTestImage(
        width: 4,
        height: 3,
        cache: false,
      );
      final WbDesktopBackdropController controller =
          WbDesktopBackdropController(
        capture: capture,
        decoder: (WbCaptureFrame _) async => fake,
      );
      addTearDown(controller.dispose);

      controller.sync(
        annotationActive: true,
        transparentApplied: false,
        penetrating: false,
      );
      await _waitFor(() => controller.image != null);

      controller.sync(
        annotationActive: false,
        transparentApplied: false,
        penetrating: false,
      );
      expect(controller.isActive, isFalse);
      expect(controller.image, isNull);
      expect(fake.debugDisposed, isTrue);
    });
  });

  group('穿透态定时刷新', () {
    test('穿透态按 refreshInterval 周期性刷新；切回批注暂停', () async {
      final _FakeCapture capture = _FakeCapture(frame: _frame());
      final WbDesktopBackdropController controller =
          WbDesktopBackdropController(
        capture: capture,
        decoder: (WbCaptureFrame _) =>
            createTestImage(width: 4, height: 3, cache: false),
        refreshInterval: const Duration(milliseconds: 30),
      );
      addTearDown(controller.dispose);

      controller.sync(
        annotationActive: true,
        transparentApplied: false,
        penetrating: true,
      );
      await _waitFor(
        () => capture.calls >= 3,
        reason: '穿透态未按期刷新截图',
      );

      controller.sync(
        annotationActive: true,
        transparentApplied: false,
        penetrating: false,
      );
      final int calls = capture.calls;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(capture.calls, calls);
    });
  });

  group('默认 BGRA 解码', () {
    test('含行距填充的帧解码：尺寸正确、连续帧替换且旧图释放', () async {
      final _FakeCapture capture = _FakeCapture(
        frame: _frame(width: 3, height: 2, stride: 16),
      );
      final WbDesktopBackdropController controller =
          WbDesktopBackdropController(capture: capture);
      addTearDown(controller.dispose);

      controller.sync(
        annotationActive: true,
        transparentApplied: false,
        penetrating: false,
      );
      await _waitFor(() => controller.image != null);
      final ui.Image first = controller.image!;
      expect(first.width, 3);
      expect(first.height, 2);

      await controller.refresh();
      final ui.Image second = controller.image!;
      expect(identical(first, second), isFalse);
      expect(first.debugDisposed, isTrue);
    });
  });

  group('静默降级', () {
    test('抓取返回 null：保持无背景且不抛出', () async {
      final _FakeCapture capture = _FakeCapture();
      final WbDesktopBackdropController controller =
          WbDesktopBackdropController(capture: capture);
      addTearDown(controller.dispose);

      controller.sync(
        annotationActive: true,
        transparentApplied: false,
        penetrating: false,
      );
      expect(controller.isActive, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.image, isNull);
      expect(capture.calls, greaterThanOrEqualTo(1));
    });

    test('抓取抛错：静默吸收且 isCapturing 复位', () async {
      final _FakeCapture capture = _FakeCapture(
        frame: _frame(),
        throwOnCapture: true,
      );
      final WbDesktopBackdropController controller =
          WbDesktopBackdropController(capture: capture);
      addTearDown(controller.dispose);

      controller.sync(
        annotationActive: true,
        transparentApplied: false,
        penetrating: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.image, isNull);
      expect(controller.isCapturing, isFalse);
    });

    test('dispose 后再 sync：不激活、不抓帧、不抛异常', () async {
      final _FakeCapture capture = _FakeCapture(frame: _frame());
      final WbDesktopBackdropController controller =
          WbDesktopBackdropController(capture: capture);
      controller.dispose();

      controller.sync(
        annotationActive: true,
        transparentApplied: false,
        penetrating: false,
      );
      expect(controller.isActive, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(capture.calls, 0);
    });
  });
}
