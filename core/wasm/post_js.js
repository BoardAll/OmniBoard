// post_js.js — post-js injection for the Emscripten MODULARIZE factory
// (WB_BUILD_WASM builds only; wired up via --post-js in core/src/CMakeLists).
//
// The Dart bindings in platform/web access `malloc` / `free` / `utf8ToString`
// / `heapU8` directly on the module object (see wb_core_bindings_web.dart),
// while EXPORTED_FUNCTIONS only produces `Module['_malloc']` /
// `Module['_free']` and EXPORTED_RUNTIME_METHODS publishes
// `Module['UTF8ToString']` / `Module['HEAPU8']` (capitalised). These aliases
// close the gap. Function aliases forward through closures so the lookup
// happens at call time — post-js code runs before WASM instantiation assigns
// the targets, and copying values eagerly would capture `undefined`.

Module['malloc'] = function (size) { return Module['_malloc'](size); };
Module['free'] = function (ptr) { Module['_free'](ptr); };
Module['utf8ToString'] = function (ptr) { return Module['UTF8ToString'](ptr); };

// `heapU8` is a property, not a function: expose it as a live getter so the
// view stays valid across ALLOW_MEMORY_GROWTH re-creations of `HEAPU8`.
Object.defineProperty(Module, 'heapU8', {
  configurable: true,
  get: function () { return Module['HEAPU8']; },
});
