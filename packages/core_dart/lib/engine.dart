/// engine.dart — 平台中立的引擎调用面（FFI / WASM 共用契约）。
///
/// 域服务（`services/*`）一律依赖本接口而非具体实现：
/// - 桌面：`WbCoreFfi`（`dart:ffi`，动态库 `wb_core.dll` / `libwb_core.so`）；
/// - Web：`WbCoreWasm`（`dart:js_interop`，Emscripten `ccall`，导出符号
///   由 `core/src/CMakeLists.txt` 从 `wb.h` 全量派生——两端能力集一致）。
///
/// 调用形态按 C ABI 参数表区分（与 `wb_core_bindings.dart` 的 typedef
/// 一一对应）；`fn` 一律为导出符号名（如 `wb_element_list`）。
/// 返回 `const char*` 的方法由实现读出 UTF-8 并释放内存；空指针 /
/// 调用失败返回空串（不抛异常，错误经 JSON 信封的 `error` 字段表达）。
///
/// 本文件不引入任何平台库（无 `dart:ffi` / `dart:js_interop`），
/// 可同时被桌面与 Web 目标编译。
library;

/// 引擎调用器（跨平台同步调用契约）。
abstract interface class WbEngineCaller {
  /// 初始化引擎（返回 0 表示成功；见 `wb.h` `wb_init`）。
  int init([String configJson]);

  /// 关闭引擎（幂等）。
  void shutdown();

  /// 引擎版本串（裸字符串，非 JSON 信封）。
  String versionString();

  /// `const char* f()`
  String call0(String fn);

  /// `const char* f(const char*)`
  String call1(String fn, String a);

  /// `const char* f(const char*, const char*)`
  String call2(String fn, String a, String b);

  /// `const char* f(const char*, const char*, const char*)`
  String call3(String fn, String a, String b, String c);

  /// `const char* f(int)`
  String callInt(String fn, int value);

  /// `const char* f(const char*, int)`
  String call1Int(String fn, String a, int value);

  /// `const char* f(const char*, int, int)`
  String call1Int2(String fn, String a, int x, int y);

  /// `const char* f(const char*, int, const char*)`
  String call1Int1(String fn, String a, int value, String b);

  /// `const char* f(const char*, float, float)`
  String call1Float2(String fn, String a, double x, double y);

  /// `const char* f(float, float, float)`
  String callFloat3(String fn, double x, double y, double z);

  /// `const char* f(uint64_t)`
  String callHandle(String fn, int handle);

  /// `const char* f(uint64_t, const char*)`
  String callHandle1(String fn, int handle, String a);

  /// `const char* f(uint64_t, int)`
  String callHandleInt(String fn, int handle, int value);

  /// `const char* f(uint64_t, const char*, int, int)`
  String callHandle1Int2(
    String fn,
    int handle,
    String a,
    int x,
    int y,
  );

  /// `uint64_t f(const char*)`（如 `wb_create_board` 返回句柄）。
  int callU64(String fn, String a);

  /// `void f(uint64_t)`（如 `wb_destroy_board`）。
  void callVoidHandle(String fn, int handle);
}
