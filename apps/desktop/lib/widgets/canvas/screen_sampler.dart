/// 屏幕采样器：Windows 桌面下经 GDI 直接采样屏幕像素与全局输入状态，
/// 供全屏取色（吸管）使用——放大镜跟随光标、点击屏幕任意位置取色，
/// 不受应用窗口范围限制。
///
/// 全部 API 同步调用（[WbScreenSampler.tryOpen] / [WbScreenSampler.cursor]
/// / [WbScreenSampler.colorAt] / [WbScreenSampler.patch]），由取色层以
/// 固定周期轮询；非 Windows / 系统调用不可用时 [WbScreenSampler.tryOpen]
/// 返回 null，调用方降级为画布内取色（见 `canvas_capture.dart`）。
///
/// 实现说明（`dart:ffi` 直调 user32 / gdi32）：
/// - `GetCursorPos` 取全局光标（虚拟桌面物理像素坐标，多屏可为负）；
/// - `GetAsyncKeyState` 取鼠标左键 / Esc 的当前按下状态；
/// - `GetDC(null)` + `GetPixel` 采样屏幕像素（含其它应用窗口内容）。
library;

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:ui' show Color;

import 'package:ffi/ffi.dart';

// ---- Win32 常量 -----------------------------------------------------------

/// `GetAsyncKeyState` 虚拟键码：鼠标左键。
const int _vkLeftButton = 0x01;

/// `GetAsyncKeyState` 虚拟键码：Esc。
const int _vkEscape = 0x1B;

/// `GetSystemMetrics` 索引：虚拟屏幕左上角 X / Y 与宽 / 高（多屏可为负）。
const int _smXVirtualScreen = 76;
const int _smYVirtualScreen = 77;
const int _smCxVirtualScreen = 78;
const int _smCyVirtualScreen = 79;

/// `GetPixel` 无效返回值（CLR_INVALID）。
const int _clrInvalid = 0xFFFFFFFF;

/// 采样块半径上限（防误用导致大列表分配）。
const int _maxPatchRadius = 64;

// ---- FFI 结构体与函数签名 --------------------------------------------------

/// Win32 `POINT`（两个 32 位 LONG）。
final class _WbPoint extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

typedef _GetCursorPosNative = Int32 Function(Pointer<_WbPoint>);
typedef _GetCursorPosDart = int Function(Pointer<_WbPoint>);
typedef _GetAsyncKeyStateNative = Int16 Function(Int32);
typedef _GetAsyncKeyStateDart = int Function(int);
typedef _GetDCNative = IntPtr Function(IntPtr);
typedef _GetDCDart = int Function(int);
typedef _ReleaseDCNative = Int32 Function(IntPtr, IntPtr);
typedef _ReleaseDCDart = int Function(int, int);
typedef _GetSystemMetricsNative = Int32 Function(Int32);
typedef _GetSystemMetricsDart = int Function(int);
typedef _GetPixelNative = Uint32 Function(IntPtr, Int32, Int32);
typedef _GetPixelDart = int Function(int, int, int);

/// 屏幕采样会话。用完必须 [dispose]（释放复用的 POINT 缓冲）。
class WbScreenSampler {
  WbScreenSampler._(
    this._getCursorPos,
    this._getAsyncKeyState,
    this._getDC,
    this._releaseDC,
    this._getSystemMetrics,
    this._getPixel,
  );

  final _GetCursorPosDart _getCursorPos;
  final _GetAsyncKeyStateDart _getAsyncKeyState;
  final _GetDCDart _getDC;
  final _ReleaseDCDart _releaseDC;
  final _GetSystemMetricsDart _getSystemMetrics;
  final _GetPixelDart _getPixel;

  /// 复用的 POINT 缓冲（避免每次轮询分配）。
  final Pointer<_WbPoint> _point = calloc<_WbPoint>();

  /// 虚拟屏幕范围（打开时读取一次；多屏坐标可为负）。
  late final int _virtualLeft = _getSystemMetrics(_smXVirtualScreen);
  late final int _virtualTop = _getSystemMetrics(_smYVirtualScreen);
  late final int _virtualWidth = _getSystemMetrics(_smCxVirtualScreen);
  late final int _virtualHeight = _getSystemMetrics(_smCyVirtualScreen);

  bool _disposed = false;

  /// 尝试打开屏幕采样会话；非 Windows / 库或符号缺失时返回 null。
  static WbScreenSampler? tryOpen() {
    if (!Platform.isWindows) {
      return null;
    }
    try {
      final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
      final DynamicLibrary gdi32 = DynamicLibrary.open('gdi32.dll');
      return WbScreenSampler._(
        user32.lookupFunction<_GetCursorPosNative, _GetCursorPosDart>(
          'GetCursorPos',
        ),
        user32.lookupFunction<_GetAsyncKeyStateNative, _GetAsyncKeyStateDart>(
          'GetAsyncKeyState',
        ),
        user32.lookupFunction<_GetDCNative, _GetDCDart>('GetDC'),
        user32.lookupFunction<_ReleaseDCNative, _ReleaseDCDart>('ReleaseDC'),
        user32.lookupFunction<_GetSystemMetricsNative, _GetSystemMetricsDart>(
          'GetSystemMetrics',
        ),
        gdi32.lookupFunction<_GetPixelNative, _GetPixelDart>('GetPixel'),
      );
    } catch (_) {
      // 加载失败（非 Windows 内核 / 受限环境）：降级为 null。
      return null;
    }
  }

  /// 全局光标位置（虚拟桌面物理像素；读取失败返回 null）。
  ({int x, int y})? cursor() {
    if (_disposed || _getCursorPos(_point) == 0) {
      return null;
    }
    return (x: _point.ref.x, y: _point.ref.y);
  }

  /// 鼠标左键当前是否按下。
  bool get leftDown => _disposed ? false : _keyDown(_vkLeftButton);

  /// Esc 当前是否按下（取色层据此取消）。
  bool get escapeDown => _disposed ? false : _keyDown(_vkEscape);

  /// 读取屏幕坐标 ([x], [y]) 的颜色；采样失败返回 null。
  ///
  /// 坐标超出虚拟屏幕时夹取到最近的有效像素。
  Color? colorAt(int x, int y) {
    return _withScreenDc((int dc) {
      final int ref = _getPixel(dc, _clampX(x), _clampY(y));
      return ref == _clrInvalid ? null : _colorFromRef(ref);
    });
  }

  /// 以屏幕坐标 ([x], [y]) 为中心取 (2*[radius]+1)² 像素块。
  ///
  /// 行主序：中心像素索引为 `radius * (2*radius+1) + radius`；块内
  /// 越界像素夹取到最近有效像素；任一像素采样失败整体返回 null。
  List<Color>? patch(int x, int y, {required int radius}) {
    if (radius < 0 || radius > _maxPatchRadius) {
      return null;
    }
    return _withScreenDc((int dc) {
      final int side = radius * 2 + 1;
      final List<Color> cells =
          List<Color>.filled(side * side, const Color(0xFF000000));
      for (int row = 0; row < side; row++) {
        final int py = _clampY(y + row - radius);
        for (int col = 0; col < side; col++) {
          final int ref = _getPixel(dc, _clampX(x + col - radius), py);
          if (ref == _clrInvalid) {
            return null;
          }
          cells[row * side + col] = _colorFromRef(ref);
        }
      }
      return cells;
    });
  }

  /// 释放会话（幂等）。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    calloc.free(_point);
  }

  // ---- 内部实现 -----------------------------------------------------------

  /// `GetAsyncKeyState` 高位（0x8000）表示当前按下。
  bool _keyDown(int vk) => _getAsyncKeyState(vk) & 0x8000 != 0;

  /// 打开屏幕 DC 执行 [action] 后释放；DC 无效或已释放返回 null。
  T? _withScreenDc<T>(T? Function(int dc) action) {
    if (_disposed) {
      return null;
    }
    final int dc = _getDC(0);
    if (dc == 0) {
      return null;
    }
    try {
      return action(dc);
    } finally {
      _releaseDC(0, dc);
    }
  }

  /// X 夹取至虚拟屏幕范围（多屏左 / 上方向坐标可为负）。
  int _clampX(int x) {
    if (_virtualWidth <= 0) {
      return x < 0 ? 0 : x;
    }
    return x.clamp(_virtualLeft, _virtualLeft + _virtualWidth - 1);
  }

  /// Y 夹取至虚拟屏幕范围（多屏左 / 上方向坐标可为负）。
  int _clampY(int y) {
    if (_virtualHeight <= 0) {
      return y < 0 ? 0 : y;
    }
    return y.clamp(_virtualTop, _virtualTop + _virtualHeight - 1);
  }

  /// COLORREF（0x00BBGGRR）→ 不透明 Color。
  Color _colorFromRef(int ref) => Color.fromARGB(
        0xFF,
        ref & 0xFF,
        (ref >> 8) & 0xFF,
        (ref >> 16) & 0xFF,
      );
}
