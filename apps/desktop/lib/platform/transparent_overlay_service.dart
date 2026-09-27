/// 透明批注模式服务：状态机 + 平台窗口能力（透明 / 置顶 / 穿透 / 全屏）。
///
/// 对照《透明批注模式技术方案》§3：
/// - [enter]：记录窗口原始 bounds → 虚拟屏全屏 → 背景透明（记录原生
///   结果，见 [isTransparentApplied]）→ 置顶；
/// - [setPenetrate]：窗口级鼠标穿透（`window.setIgnoreMouseEvents`，
///   `forward` 保留鼠标移动消息用于悬停高亮）；
/// - [exit]：依次还原穿透 / 全屏 / 透明 / 置顶 / bounds。
///
/// 平台插件（[WbWindowPlugin]，经 `whiteboard_windows` 通道）缺失时
/// （未打包 / 单元测试 / 非 Windows）全部静默降级：只切换应用内 UI 状态，
/// 不抛出、不崩溃。
library;

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:whiteboard_windows/whiteboard_windows.dart';
import 'package:window_manager/window_manager.dart';

/// 透明批注模式的阶段。
enum WbOverlayPhase {
  /// 关闭。
  off('关闭'),

  /// 准备中（窗口调整）。
  preparing('准备中'),

  /// 批注进行中。
  active('批注中'),

  /// 退出中（窗口还原）。
  exiting('退出中');

  const WbOverlayPhase(this.label);

  /// 中文显示名。
  final String label;
}

/// 窗口几何快照（进入透明批注前的原始 bounds，退出时还原）。
@immutable
class WbWindowBounds {
  const WbWindowBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 屏幕坐标（逻辑像素）。
  final double left;

  /// 屏幕坐标（逻辑像素）。
  final double top;

  /// 窗口尺寸（逻辑像素）。
  final double width;

  /// 窗口尺寸（逻辑像素）。
  final double height;

  /// 转换为 [Rect]。
  Rect toRect() => Rect.fromLTWH(left, top, width, height);
}

/// 窗口几何读写抽象（默认实现经 `window_manager`；测试可注入替身）。
abstract class WbOverlayWindowGeometry {
  /// 读取窗口当前 bounds；平台不可用时返回 null（静默降级）。
  Future<WbWindowBounds?> read();

  /// 还原窗口 bounds；平台不可用时静默忽略。
  Future<void> restore(WbWindowBounds bounds);
}

/// 默认几何实现：`window_manager`（插件缺失 / 测试环境静默降级）。
class WbWindowManagerGeometry implements WbOverlayWindowGeometry {
  const WbWindowManagerGeometry();

  @override
  Future<WbWindowBounds?> read() async {
    try {
      final Rect bounds = await windowManager.getBounds();
      return WbWindowBounds(
        left: bounds.left,
        top: bounds.top,
        width: bounds.width,
        height: bounds.height,
      );
    } catch (_) {
      // 插件不可用（测试 / 未打包）：降级为 null。
      return null;
    }
  }

  @override
  Future<void> restore(WbWindowBounds bounds) async {
    try {
      await windowManager.setBounds(bounds.toRect());
    } catch (_) {
      // 静默降级。
    }
  }
}

/// 透明批注模式服务（[ChangeNotifier]）。
///
/// 对外契约与既有骨架一致（[phase] / [isActive] / [enter] / [exit] /
/// [toggle]），本类内部完成真实平台接线；[setPenetrate] 供批注控制器
/// 同步「批注 / 鼠标」两种模式的窗口穿透。
class WbTransparentOverlayService extends ChangeNotifier {
  WbTransparentOverlayService({
    WbWindowPlugin? plugin,
    WbOverlayWindowGeometry? geometry,
  })  : _plugin = plugin ?? WindowsWindowPlugin(),
        _geometry = geometry ?? const WbWindowManagerGeometry();

  final WbWindowPlugin _plugin;
  final WbOverlayWindowGeometry _geometry;

  WbOverlayPhase _phase = WbOverlayPhase.off;
  bool _penetrating = false;
  bool _transparentApplied = false;
  WbWindowBounds? _savedBounds;

  /// 当前阶段。
  WbOverlayPhase get phase => _phase;

  /// 是否处于批注中。
  bool get isActive => _phase == WbOverlayPhase.active;

  /// 是否处于穿透态（鼠标事件传给系统）。
  bool get isPenetrating => _penetrating;

  /// 原生背景透明是否已生效。
  ///
  /// 仅原生明确返回 true 才为 true；API 缺失（旧系统）/ 调用失败 /
  /// 测试环境为 false，上层据此降级（例如改用虚拟屏截图作批注页背景）。
  bool get isTransparentApplied => _transparentApplied;

  /// 进入前记录的窗口原始几何（未记录 / 已还原时为 null）。
  WbWindowBounds? get savedBounds => _savedBounds;

  /// 进入透明批注模式（幂等）。
  ///
  /// 顺序：记录窗口 bounds → 虚拟屏全屏（覆盖多屏）→ 背景透明（记录
  /// 原生结果，供 [isTransparentApplied] 判定降级）→ 置顶；默认回到
  /// 批注态（不穿透）。
  Future<void> enter() async {
    if (_phase == WbOverlayPhase.active ||
        _phase == WbOverlayPhase.preparing) {
      return;
    }
    _phase = WbOverlayPhase.preparing;
    notifyListeners();
    _savedBounds = await _geometry.read();
    await _safe(() => _plugin.setFullscreen(true));
    _transparentApplied = await _safeBool(() => _plugin.setTransparent(true));
    await _safe(() => _plugin.setAlwaysOnTop(true));
    _penetrating = false;
    _phase = WbOverlayPhase.active;
    notifyListeners();
  }

  /// 同步鼠标穿透：true = 穿透（操作电脑），false = 批注（捕获绘制）。
  Future<void> setPenetrate(bool penetrate) async {
    final bool changed = _penetrating != penetrate;
    _penetrating = penetrate;
    if (changed) {
      notifyListeners();
    }
    if (!isActive) {
      // 未激活（含测试环境降级路径）：不触碰平台窗口。
      return;
    }
    await _safe(
      () => _plugin.setIgnoreMouseEvents(penetrate, forward: penetrate),
    );
  }

  /// 退出透明批注模式并还原窗口（幂等）。
  Future<void> exit() async {
    if (_phase == WbOverlayPhase.off || _phase == WbOverlayPhase.exiting) {
      return;
    }
    _phase = WbOverlayPhase.exiting;
    notifyListeners();
    await _safe(() => _plugin.setIgnoreMouseEvents(false));
    await _safe(() => _plugin.setFullscreen(false));
    await _safe(() => _plugin.setTransparent(false));
    await _safe(() => _plugin.setAlwaysOnTop(false));
    final WbWindowBounds? saved = _savedBounds;
    if (saved != null) {
      await _safe(() => _geometry.restore(saved));
    }
    _savedBounds = null;
    _penetrating = false;
    _transparentApplied = false;
    _phase = WbOverlayPhase.off;
    notifyListeners();
  }

  /// 切换（便捷入口）。
  Future<void> toggle() => isActive ? exit() : enter();

  /// 平台调用降级包装：插件缺失 / 非 Windows 环境静默忽略。
  Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // 静默降级：覆盖层能力不可用不影响应用内批注流程。
    }
  }

  /// 平台调用降级包装（布尔结果版）：异常 / 插件缺失一律 false。
  Future<bool> _safeBool(Future<bool> Function() action) async {
    try {
      return await action();
    } catch (_) {
      return false;
    }
  }
}
