// wb_core.js — Whiteboard C++ 核心（WASM）占位脚本（Wave 2.10）。
//
// 本文件是占位示例：真实的 wb_core.js / wb_core.wasm 由 Emscripten
// 构建产出（-s MODULARIZE=1 -s EXPORT_NAME=WbCore；
// tools\scripts\build_wasm.ps1 -CopyToWebAssets 可直接覆盖宿主
// apps/web/web/ 下同名文件，2026-10-01 已接入）。
//
// 注入本脚本后：本脚本【不会】定义 window.WbCore，WbCoreLoader 探测到
// "核心不可用"（WbCoreStatus.unavailable），Web 端以演示画布降级运行，
// 不阻塞 UI。
(function () {
  'use strict';

  if (typeof window === 'undefined') {
    return;
  }

  // 真实构建产物若已先行加载（window.WbCore 工厂存在），不做任何事。
  if (typeof window.WbCore === 'function') {
    return;
  }

  // 供调试面板 / 构建脚本探测占位状态。
  window.__WB_CORE_PLACEHOLDER__ = true;

  console.info(
    '[whiteboard] wb_core.js 当前为占位脚本：真实的 C++ WASM 核心' +
      '（wb_core.js + wb_core.wasm）由 Emscripten 构建产出，' +
      '并覆盖 apps/web/web/ 下同名文件；本占位文件下 Web 端以演示画布' +
      '降级运行（WbCoreLoader → unavailable）。',
  );
})();
