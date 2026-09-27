/// WASM 核心加载器（`wb_core.js` / `wb_core.wasm`）的非 Web 桩实现。
///
/// Windows / macOS / Linux VM（`flutter test` / 桌面宿主）上不存在浏览器
/// Script 与 Emscripten 运行时：`load()` 立即返回
/// [WbCoreStatus.unavailable]（不抛异常），`call` / `cwrap` 返回 null，
/// 保证上层代码可直接调用而无需平台分支（《Web 端方案设计
/// （Flutter Web + WASM）v1.0》§6、§9.4）。
///
/// 公共 API 与 Web 版（`wb_core_loader_web.dart`）保持同名同签名。
library;

import 'dart:async';

import 'wb_core_bindings_stub.dart';
import 'wb_core_types.dart';

/// WASM 核心加载器（非 Web 桩）。
class WbCoreLoader {
  /// 创建加载器（参数仅占位，非 Web 环境不做任何加载）。
  WbCoreLoader({
    this.scriptUrl = defaultScriptUrl,
    this.loadTimeout = defaultLoadTimeout,
  });

  /// 默认脚本路径（与 Web 版一致）。
  static const String defaultScriptUrl = 'wb_core.js';

  /// 默认加载超时（与 Web 版一致）。
  static const Duration defaultLoadTimeout = Duration(seconds: 15);

  /// 脚本 URL（占位）。
  final String scriptUrl;

  /// 加载超时（占位）。
  final Duration loadTimeout;

  WbCoreStatus _status = WbCoreStatus.idle;

  /// 当前加载状态（非 Web 环境在 [load] 后恒为
  /// [WbCoreStatus.unavailable]）。
  WbCoreStatus get status => _status;

  /// 是否已加载并可用（非 Web 环境恒为 false）。
  bool get isAvailable => _status.isAvailable;

  /// 已加载的模块（非 Web 环境恒为 null）。
  WbCoreModule? get module => null;

  /// 加载进度（桩：仅产出 0.0 与 1.0 两个值）。
  Stream<double> get progress =>
      Stream<double>.fromIterable(const <double>[0.0, 1.0]);

  /// 尝试加载 WASM 核心。
  ///
  /// 非 Web 环境直接返回 [WbCoreStatus.unavailable]，不抛异常。
  Future<WbCoreStatus> load() async {
    _status = WbCoreStatus.unavailable;
    return _status;
  }

  /// `ccall` 代理（桩：恒返回 null）。
  Future<Object?> call(
    String name, [
    List<Object?> args = const <Object?>[],
  ]) async {
    return null;
  }

  /// `cwrap` 代理（桩：恒返回 null）。
  WbCoreCallable? cwrap(
    String name, {
    String? returnType,
    List<String> argTypes = const <String>[],
  }) {
    return null;
  }

  /// 释放加载器资源（桩：no-op）。
  void dispose() {}
}
