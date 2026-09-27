/// Emscripten Module 绑定的非 Web 占位类型。
///
/// Windows / macOS / Linux VM（`flutter test` / 桌面宿主）上不存在
/// JS 运行时：本文件仅保证 [WbCoreModule] 类型可用，
/// 所有方法恒返回空值，不会被真实的 WASM 模块实例化路径触及。
library;

import 'dart:typed_data';

/// Emscripten Module 绑定的非 Web 占位类型（公共 API 与 Web 版同名）。
class WbCoreModule {
  const WbCoreModule._unsupported();

  /// 占位实例（非 Web 环境仅用于类型占位，无实际能力）。
  static const WbCoreModule unsupported = WbCoreModule._unsupported();

  /// `ccall` 占位（恒返回 null）。
  Object? ccall(
    String ident,
    String? returnType,
    Object? argTypes,
    Object? args,
  ) =>
      null;

  /// `cwrap` 占位（恒返回 null）。
  Object? cwrap(String ident, String? returnType, Object? argTypes) => null;

  /// `UTF8ToString` 占位（恒返回空串；对应 Emscripten `UTF8ToString`）。
  String utf8ToString(int ptr) => '';

  /// `_malloc` 占位（恒返回 0）。
  int malloc(int size) => 0;

  /// `_free` 占位（no-op）。
  void free(int ptr) {}

  /// 读取 WASM 线性内存占位（恒返回空列表）。
  Uint8List readBytes(int ptr, int size) => Uint8List(0);
}
