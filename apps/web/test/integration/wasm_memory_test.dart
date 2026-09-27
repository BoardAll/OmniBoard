/// apps/web WASM 集成测试（《测试方案设计》§7.3）—— 内存接口与错误处理。
///
/// VM 环境没有真实 wasm，本文件验证 platform/web 的
/// **内存统计接口形状**与异常安全（不做真实 wasm 执行）：
/// - 统计 / 分配类符号调用在桩下返回 null（无原生内存可读）；
/// - [WbCoreModule] 的 `malloc` / `free` / `readBytes` 占位语义
///   （0 / no-op / 空列表）；
/// - 高频调用与 dispose 后的接口安全性（不抛异常、无状态泄漏）。
///
/// 真实堆行为（`wb_memory_stats` 数值、线性内存读取）由 C++ 侧
/// 单测与桌面 FFI 集成测试（`test/integration/ffi_memory_test.dart`）覆盖。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_web/services/wb_core_service.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

void main() {
  group('内存统计调用（非 Web 桩）', () {
    test('wb_memory_stats 返回 null：无原生内存可统计', () async {
      final WbCoreLoader loader = WbCoreLoader();
      await loader.load();
      expect(await loader.call('wb_memory_stats'), isNull);
    });

    test('分配 / 释放类调用（wb_alloc / wb_free）安全返回 null', () async {
      final WbCoreLoader loader = WbCoreLoader();
      expect(await loader.call('wb_alloc', <Object?>[1024]), isNull);
      expect(await loader.call('wb_free', <Object?>[0]), isNull);
    });

    test('服务层面：不可用时 isAvailable=false（内存统计不对外承诺）', () async {
      final WbCoreService service = WbCoreService();
      addTearDown(service.dispose);
      await service.initialize();
      expect(service.status, WbCoreStatus.unavailable);
      expect(service.isAvailable, isFalse);
    });
  });

  group('WbCoreModule 内存原语（占位语义）', () {
    test('malloc 恒返回 0（无 WASM 堆）', () {
      const WbCoreModule module = WbCoreModule.unsupported;
      expect(module.malloc(16), 0);
      expect(module.malloc(1 << 20), 0);
    });

    test('free 为 no-op：任意指针调用均不抛异常', () {
      const WbCoreModule module = WbCoreModule.unsupported;
      module.free(0);
      module.free(-1);
      module.free(0x7fffffff);
    });

    test('readBytes(0, 0) 与超界读取均返回空列表（长度断言）', () {
      const WbCoreModule module = WbCoreModule.unsupported;
      expect(module.readBytes(0, 0).length, 0);
      expect(module.readBytes(0, 8).length, 0);
      expect(module.readBytes(-1, 64).length, 0);
    });

    test('高频分配 / 释放循环无状态泄漏（结果稳定）', () {
      const WbCoreModule module = WbCoreModule.unsupported;
      for (int i = 0; i < 1000; i += 1) {
        final int ptr = module.malloc(64);
        expect(ptr, 0);
        module.free(ptr);
      }
    });
  });

  group('调用安全性（错误处理）', () {
    test('未知符号 / 空名称调用返回 null 不抛异常', () async {
      final WbCoreLoader loader = WbCoreLoader();
      expect(await loader.call('wb_not_a_real_symbol'), isNull);
      expect(await loader.call(''), isNull);
    });

    test('dispose 后内存接口仍安全（桩为 no-op）', () async {
      final WbCoreLoader loader = WbCoreLoader();
      loader.dispose();
      expect(await loader.call('wb_memory_stats'), isNull);
      expect(WbCoreModule.unsupported.malloc(8), 0);
    });

    test('loader.module 在桩下恒为 null（无内存视图）', () {
      final WbCoreLoader loader = WbCoreLoader();
      expect(loader.module, isNull);
      loader.dispose();
      expect(loader.module, isNull);
    });
  });
}
