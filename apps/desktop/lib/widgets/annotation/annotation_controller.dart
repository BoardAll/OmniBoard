/// 透明批注控制器：状态机 / 进入退出编排 / 全局快捷键 / 保存回白板。
///
/// 对照《透明批注模式技术方案》§4-§9：
/// - 两种状态：批注态（捕获）/ 穿透态（放行），见 [setPenetrate]；
/// - 进入退出：见 [enter] / [requestExit] / [chooseExit]（退出三选项）；
/// - 全局快捷键：`Alt + Shift + A`（注册失败静默降级为工具栏切换）；
/// - 保存：批量交给 [WbAnnotationSaveHandler]（未注入时走演示路径，
///   FFI 提交点尽力同步、引擎不可用时静默降级）。
///
/// 平台能力降级说明：覆盖层窗口 / 鼠标穿透 / 全局热键的真实平台接线经
/// `whiteboard_windows` 插件（[WbTransparentOverlayService]）完成；
/// 服务不可用（未打包 / 测试环境）时本控制器只切换 UI 状态，
/// 不抛出、不崩溃。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:whiteboard_core/wb_core.dart';

import '../../platform/platform_service.dart';
import '../../platform/transparent_overlay_service.dart';
import '../../services/ffi_service.dart';
import '../../services/shortcut_service.dart';
import '../../state/annotation_state.dart';

/// 退出弹窗三选项（《透明批注模式技术方案》§5.4）。
enum WbAnnotationExitChoice {
  /// 保存到白板：批注批量写入后退出。
  saveToBoard('保存到白板', '批注合并为一个图层后退出'),

  /// 丢弃（仅批注，不写入白板）：清空批注并退出。
  discard('丢弃', '仅批注（丢弃），不保存并退出'),

  /// 取消退出 / 继续保留：保留批注层，稍后再处理。
  cancel('继续保留', '取消退出，保留批注层');

  const WbAnnotationExitChoice(this.label, this.description);

  /// 按钮标题（文档 §5.4 弹窗交互）。
  final String label;

  /// 按钮说明文案。
  final String description;
}

/// 全局热键句柄（注册成功后交由控制器负责注销）。
class WbAnnotationHotkey {
  const WbAnnotationHotkey({required this.unregister});

  /// 注销回调（幂等；平台缺失时内部静默）。
  final Future<void> Function() unregister;
}

/// 全局热键注册器；返回 null 表示平台不可用（静默降级）。
typedef WbAnnotationHotkeyRegistrar = Future<WbAnnotationHotkey?> Function(
  WbShortcut shortcut,
  VoidCallback onTrigger,
);

/// 保存到白板的批量写入编排回调（预留；Wave 4 持久化接入点）。
///
/// 返回是否保存成功；抛异常视为失败（控制器捕获并降级）。
typedef WbAnnotationSaveHandler = Future<bool> Function(
  List<WbAnnotationStroke> strokes,
);

/// 透明批注快捷键定义（与 [WbShortcutService] 约定一致）。
abstract final class WbAnnotationShortcuts {
  /// 切换穿透 / 批注：`Alt + Shift + A`（文档 §10 快捷键表）。
  static const WbShortcut togglePenetrate = WbShortcut(
    id: 'annotate.toggleTransparent',
    label: '切换穿透/批注',
    activator: SingleActivator(
      LogicalKeyboardKey.keyA,
      alt: true,
      shift: true,
    ),
    scope: WbShortcutScope.global,
  );

  /// 快捷键显示文本（如 `Alt+Shift+A`）。
  static String get togglePenetrateLabel =>
      WbShortcutService.describe(togglePenetrate.activator);
}

/// 透明批注控制器（[ChangeNotifier]，UI 层监听它即可感知全部变化）。
class WbAnnotationController extends ChangeNotifier {
  WbAnnotationController({
    WbAnnotationState? state,
    WbTransparentOverlayService? overlay,
    WbAnnotationHotkeyRegistrar? hotkeyRegistrar,
    WbAnnotationSaveHandler? onSaveToBoard,
    WbFfiService? ffi,
  })  : _state = state ?? WbAnnotationState(),
        _ownsState = state == null,
        _overlay = overlay,
        _registrar = hotkeyRegistrar ?? _platformHotkeyRegistrar,
        _saveHandler = onSaveToBoard,
        _ffi = ffi {
    _state.addListener(_relay);
  }

  final WbAnnotationState _state;
  final bool _ownsState;
  final WbTransparentOverlayService? _overlay;
  final WbAnnotationHotkeyRegistrar _registrar;
  final WbAnnotationSaveHandler? _saveHandler;
  final WbFfiService? _ffi;

  WbAnnotationHotkey? _hotkey;
  bool _exitDialogVisible = false;
  bool _temporaryPenetrate = false;
  bool _appliedPenetrate = false;
  bool _saving = false;
  String _lastError = '';

  // ---- 只读视图 ----

  /// 批注数据状态（模式 / 笔迹 / 笔刷）。
  WbAnnotationState get state => _state;

  /// 当前模式。
  WbAnnotationMode get mode => _state.mode;

  /// 是否处于透明批注模式。
  bool get isActive => _state.isActive;

  /// 是否穿透态（常规）。
  bool get isPenetrating => _state.isPenetrating;

  /// 是否按住 `Alt` 的临时穿透（文档 §4.2）。
  bool get isTemporaryPenetrate => _temporaryPenetrate;

  /// 有效穿透：常规穿透态或批注态下的临时穿透。
  bool get isPenetratingInEffect => _state.isPenetrating || _temporaryPenetrate;

  /// 退出弹窗是否可见。
  bool get exitDialogVisible => _exitDialogVisible;

  /// 是否正在保存到白板。
  bool get isSaving => _saving;

  /// 全局快捷键是否注册成功。
  bool get shortcutRegistered => _hotkey != null;

  /// 快捷键显示文本（如 `Alt+Shift+A`）。
  String get shortcutLabel => WbAnnotationShortcuts.togglePenetrateLabel;

  /// 快捷键状态描述（界面提示用；识别降级场景）。
  String get shortcutStatus {
    if (!isActive || shortcutRegistered) {
      return shortcutLabel;
    }
    return '$shortcutLabel（全局注册失败，已降级为仅工具栏切换）';
  }

  /// 最近一次错误（空串表示无错误；服务降级 / 保存失败时记录）。
  String get lastError => _lastError;

  // ---- 进入 / 退出流程（文档 §5） ----

  /// 进入透明批注模式（默认批注态；幂等）。
  ///
  /// 流程：状态切换 → FFI 提交点（尽力）→ 覆盖层服务（可降级）→
  /// 全局快捷键注册（失败静默降级）。
  Future<void> enter() async {
    if (_state.isActive) {
      return;
    }
    _lastError = '';
    _appliedPenetrate = false;
    _temporaryPenetrate = false;
    _state.enter();
    _submitFfiEnter();
    await _applyOverlayEnter();
    await _registerHotkey();
  }

  /// 退出透明批注模式（保留笔迹，便于"继续保留"场景；幂等）。
  Future<void> exit() => exitMode(action: 'keep');

  /// 退出并上报动作（`save` / `discard` / `keep`）。
  Future<void> exitMode({String action = 'keep'}) async {
    if (!_state.isActive) {
      return;
    }
    _exitDialogVisible = false;
    _temporaryPenetrate = false;
    await _unregisterHotkey();
    await _applyOverlayExit();
    _submitFfiExit(action);
    _state.exit();
    _appliedPenetrate = false;
    notifyListeners();
  }

  /// 请求退出（工具栏 ✕ / `Esc` / 再次触发快捷键）：打开退出弹窗。
  void requestExit() {
    if (!isActive || _exitDialogVisible) {
      return;
    }
    _exitDialogVisible = true;
    notifyListeners();
  }

  /// 处理退出弹窗三选项（文档 §5.4）。
  Future<void> chooseExit(WbAnnotationExitChoice choice) async {
    switch (choice) {
      case WbAnnotationExitChoice.saveToBoard:
        {
          final bool ok = await saveToBoard();
          if (ok) {
            await exitMode(action: 'save');
          }
          // 保存失败：保留弹窗与批注，等待用户重试或改选。
        }
      case WbAnnotationExitChoice.discard:
        {
          _state.discardStrokes();
          await exitMode(action: 'discard');
        }
      case WbAnnotationExitChoice.cancel:
        {
          _exitDialogVisible = false;
          notifyListeners();
        }
    }
  }

  // ---- 穿透 / 批注切换（文档 §4.3 / §12.2 / §12.3） ----

  /// 切换穿透 / 批注态（工具栏按钮与全局快捷键共用入口；未进入时忽略）。
  Future<void> togglePenetrate() async {
    if (!isActive) {
      return;
    }
    await setPenetrate(!_state.isPenetrating);
  }

  /// 设置穿透态（true = 穿透，false = 批注）。
  Future<void> setPenetrate(bool penetrate) async {
    if (!isActive) {
      return;
    }
    _state.setMode(
      penetrate ? WbAnnotationMode.penetrating : WbAnnotationMode.annotating,
    );
    await _syncPenetrateToPlatform();
  }

  /// 按住 `Alt` 的临时穿透：批注态按下临时放行，松开恢复。
  void setTemporaryPenetrate(bool value) {
    if (_temporaryPenetrate == value) {
      return;
    }
    _temporaryPenetrate = value;
    notifyListeners();
    unawaited(_syncPenetrateToPlatform());
  }

  Future<void> _syncPenetrateToPlatform() async {
    final bool want = isPenetratingInEffect;
    if (want == _appliedPenetrate) {
      return;
    }
    _appliedPenetrate = want;
    // FFI 提交点（尽力同步）：引擎可用时同步穿透状态；不可用时静默跳过。
    _callFfi(
      'setPenetrate',
      (WbEngineCaller core) =>
          core.callInt('wb_annotate_set_penetrate', want ? 1 : 0),
    );
    // 平台窗口级穿透：经覆盖层服务调用 `window.setIgnoreMouseEvents`
    // （forward 保留鼠标移动消息）；插件 / 非桌面环境内部静默降级。
    final WbTransparentOverlayService? overlay = _overlay;
    if (overlay == null) {
      return;
    }
    try {
      await overlay.setPenetrate(want);
    } catch (e) {
      _lastError = '窗口穿透同步失败（已忽略）：$e';
    }
  }

  // ---- 保存回白板（文档 §5.4 / §6.3） ----

  /// 保存到白板：把笔迹批量交给 [WbAnnotationSaveHandler]（或演示路径）。
  ///
  /// 返回是否保存成功；成功后本地批注层转换为
  /// [WbAnnotationState.savedSnapshot] 并清空。
  Future<bool> saveToBoard() async {
    final List<WbAnnotationStroke> strokes = <WbAnnotationStroke>[
      for (final WbAnnotationStroke stroke in _state.strokes)
        if (!stroke.isLaser) stroke,
    ];
    if (strokes.isEmpty) {
      _state.markSaved();
      return true;
    }
    _saving = true;
    notifyListeners();
    bool ok = false;
    try {
      final WbAnnotationSaveHandler? handler = _saveHandler;
      ok = handler != null
          ? await handler(strokes)
          : await _defaultSaveToBoard(strokes);
    } catch (e) {
      _lastError = '保存到白板失败：$e';
    }
    _saving = false;
    if (ok) {
      _state.markSaved();
    }
    notifyListeners();
    return ok;
  }

  /// 演示路径：内存接受（无引擎环境可完整走通流程）。
  ///
  /// 真实批量写入由上层注入 [WbAnnotationSaveHandler] 完成（Wave 4 持久化）；
  /// wb.h 目前仅暴露 `wb_annotate_enter/exit_transparent` 与
  /// `wb_annotate_set_penetrate` 三个提交点（详见 [enter] / [exitMode]）。
  Future<bool> _defaultSaveToBoard(List<WbAnnotationStroke> strokes) async {
    return true;
  }

  // ---- 内部：覆盖层服务联动（可降级） ----

  Future<void> _applyOverlayEnter() async {
    final WbTransparentOverlayService? overlay = _overlay;
    if (overlay == null) {
      return;
    }
    try {
      await overlay.enter();
    } catch (e) {
      _lastError = '透明覆盖服务不可用（已降级为纯界面批注）：$e';
      notifyListeners();
    }
  }

  Future<void> _applyOverlayExit() async {
    final WbTransparentOverlayService? overlay = _overlay;
    if (overlay == null) {
      return;
    }
    try {
      await overlay.exit();
    } catch (e) {
      _lastError = '透明覆盖服务还原失败（已忽略）：$e';
      notifyListeners();
    }
  }

  // ---- 内部：全局快捷键（注册失败静默降级） ----

  Future<void> _registerHotkey() async {
    if (_hotkey != null) {
      return;
    }
    try {
      final WbAnnotationHotkey? hotkey = await _registrar(
        WbAnnotationShortcuts.togglePenetrate,
        () => unawaited(togglePenetrate()),
      );
      _hotkey = hotkey;
    } catch (e) {
      _hotkey = null;
      _lastError = '全局快捷键注册失败（已降级为应用内切换）：$e';
    }
    notifyListeners();
  }

  Future<void> _unregisterHotkey() async {
    final WbAnnotationHotkey? hotkey = _hotkey;
    if (hotkey == null) {
      return;
    }
    _hotkey = null;
    await _safeUnregister(hotkey);
    notifyListeners();
  }

  Future<void> _safeUnregister(WbAnnotationHotkey hotkey) async {
    try {
      await hotkey.unregister();
    } catch (_) {
      // 注销失败忽略（平台缺失 / 进程退出）。
    }
  }

  // ---- 内部：FFI 提交点（尽力同步，引擎不可用时不报错） ----

  void _submitFfiEnter() {
    _callFfi(
      'enterTransparent',
      (WbEngineCaller core) => core.call1(
        'wb_annotate_enter_transparent',
        jsonEncode(<String, Object?>{'mode': 'annotating'}),
      ),
    );
  }

  void _submitFfiExit(String action) {
    _callFfi(
      'exitTransparent',
      (WbEngineCaller core) => core.call1(
        'wb_annotate_exit_transparent',
        jsonEncode(<String, Object?>{'action': action}),
      ),
    );
  }

  void _callFfi(String op, String Function(WbEngineCaller core) body) {
    final WbFfiService? service = _ffi;
    if (service == null || !service.isAvailable) {
      return;
    }
    try {
      final WbEngineCaller core = service.ffi!;
      body(core);
    } catch (e) {
      _lastError = '引擎提交失败（$op）：$e';
    }
  }

  void _relay() => notifyListeners();

  @override
  void dispose() {
    _state.removeListener(_relay);
    final WbAnnotationHotkey? hotkey = _hotkey;
    _hotkey = null;
    if (hotkey != null) {
      unawaited(_safeUnregister(hotkey));
    }
    if (_ownsState) {
      _state.dispose();
    }
    super.dispose();
  }
}

// ---- 默认全局热键注册（hotkey_manager；平台缺失 / 测试环境静默降级） ----

/// 默认注册器：通过 `hotkey_manager` 注册系统级热键。
///
/// 以下场景直接返回 null（静默降级，不抛异常）：
/// - Web / 非桌面平台；
/// - 测试环境（`FLUTTER_TEST` / TestWidgetsFlutterBinding）；
/// - 平台插件缺失或注册失败。
Future<WbAnnotationHotkey?> _platformHotkeyRegistrar(
  WbShortcut shortcut,
  VoidCallback onTrigger,
) async {
  if (!_canRegisterPlatformHotkey()) {
    return null;
  }
  final ShortcutActivator activator = shortcut.activator;
  if (activator is! SingleActivator) {
    return null;
  }
  final List<HotKeyModifier> modifiers = <HotKeyModifier>[
    if (activator.control) HotKeyModifier.control,
    if (activator.alt) HotKeyModifier.alt,
    if (activator.shift) HotKeyModifier.shift,
    if (activator.meta) HotKeyModifier.meta,
  ];
  final HotKey hotKey = HotKey(
    key: activator.trigger,
    modifiers: modifiers,
    scope: HotKeyScope.system,
  );
  try {
    await hotKeyManager.register(
      hotKey,
      keyDownHandler: (HotKey _) => onTrigger(),
    );
    return WbAnnotationHotkey(
      unregister: () => hotKeyManager.unregister(hotKey),
    );
  } catch (_) {
    return null;
  }
}

bool _canRegisterPlatformHotkey() {
  if (kIsWeb || !WbPlatformService.isDesktop) {
    return false;
  }
  // 测试环境（flutter test）不触碰平台通道，保证无插件环境静默降级。
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return false;
  }
  try {
    return !WidgetsBinding.instance.runtimeType.toString().contains('Test');
  } catch (_) {
    return false;
  }
}
