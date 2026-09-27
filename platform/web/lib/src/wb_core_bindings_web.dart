/// Emscripten Module 的 Web 绑定（`dart:js_interop`）。
///
/// 对应 Emscripten 构建参数（《Web 端方案设计（Flutter Web + WASM）》
/// §5.2）：
/// `-s MODULARIZE=1 -s EXPORT_NAME=WbCore`
/// `-s EXPORTED_RUNTIME_METHODS=['ccall','cwrap','UTF8ToString','HEAPU8']`。
///
/// 仅在 Web 目标编译（条件导入选择），VM 目标使用同名占位类型
/// （`wb_core_bindings_stub.dart`）。
library;

import 'dart:js_interop';
import 'dart:typed_data';

/// Emscripten Module 的 Dart 绑定视图（包装 `WbCore()` 工厂 Promise
/// 产出的模块对象）。
///
/// 绑定与导出符号的对应关系：
/// - `ccall` / `cwrap` / `utf8ToString` / `heapU8`：Emscripten 运行时方法；
/// - `malloc` → 导出符号 `_malloc`；`free` → 导出符号 `_free`。
extension type WbCoreModule._(JSObject _) implements JSObject {
  /// 从 Emscripten 模块对象创建绑定视图（加载器内部使用）。
  static WbCoreModule fromModule(JSObject jsModule) => WbCoreModule._(jsModule);

  /// 调用导出符号（Emscripten `ccall`）。
  ///
  /// [returnType] 为 `'number'` / `'string'` / `'boolean'` 或 null（数字）；
  /// [argTypes] 为参数类型数组（同前，`'string'` 时自动做 UTF8 编解码，
  /// 传 null 时按数字对待）。
  external JSAny? ccall(
    String ident,
    String? returnType,
    JSAny? argTypes,
    JSAny? args,
  );

  /// 包装导出符号为可复用的 JS 函数（Emscripten `cwrap`）。
  external JSFunction cwrap(String ident, String? returnType, JSAny? argTypes);

  /// 把 C 字符串指针转为 Dart 字符串。
  ///
  /// 对应 Emscripten 运行时方法 `UTF8ToString`。
  external String utf8ToString(int ptr);

  /// 分配 WASM 堆内存（对应导出符号 `_malloc`），返回指针。
  external int malloc(int size);

  /// 释放 WASM 堆内存（对应导出符号 `_free`）。
  external void free(int ptr);

  /// WASM 线性内存的 Uint8 视图（对应 Emscripten `HEAPU8`）。
  external JSUint8Array get heapU8;

  /// 拷贝 WASM 线性内存区间为独立 [Uint8List]（《Web 端方案设计》§7.3）。
  ///
  /// `heapU8.toDart` 在不同编译后端可能返回视图或拷贝，此处统一
  /// 以 `buffer.asUint8List` 切片再复制，保证结果不随内存增长失效。
  Uint8List readBytes(int ptr, int size) {
    final Uint8List heap = heapU8.toDart;
    return Uint8List.fromList(heap.buffer.asUint8List(ptr, size));
  }
}
