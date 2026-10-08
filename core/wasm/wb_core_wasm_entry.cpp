// wb_core_wasm_entry.cpp — Emscripten link entry for the WebAssembly core.
//
// Compiled only into the wb_core_wasm executable target (see the
// WB_BUILD_WASM branch of core/src/CMakeLists.txt). It deliberately lives
// outside src/ so the recursive source glob does not pull it into the
// wb_core library (desktop builds must not see it).
//
// The WASM build links with --no-entry: there is no main(). Every callable
// entry point is the WB_API C ABI from wb.h, exported as _wb_* and invoked
// from JS via WbCore().ccall(...) (see platform/web).

namespace wb::wasm {

// Link anchor: keeps the translation unit non-empty and gives future
// WASM-only initialization a natural home.
void wb_wasm_link_anchor() {}

}  // namespace wb::wasm
