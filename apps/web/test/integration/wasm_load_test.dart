/// apps/web WASM 集成测试（《测试方案设计》§7.3）—— 加载生命周期。
///
/// VM 环境没有真实 `wb_core.wasm`，本文件对 platform/web 的
/// **Dart 侧加载契约**做白盒验证（不做真实 wasm 执行）：
/// - [WbCoreLoader] 缺省配置 / 初始状态 / 状态机（idle → unavailable）；
/// - `load()` 在非 Web 环境不抛异常（跨平台可编译保证）；
/// - 进度流与幂等语义；
/// - [WbCoreStatus] 枚举契约（id / label / isAvailable）；
/// - [WbCoreService] 对加载器的装配（含 ready 路径的 fake 注入）。
///
/// 真实 WASM 加载（script 注入 / Promise 实例化）仅在浏览器发生，
/// 由 Wave 4 的产物 + 浏览器链路覆盖。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_web/services/wb_core_service.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

void main() {
  group('WbCoreLoader 缺省配置与初始状态', () {
    test('默认脚本路径与超时与 Web 版契约一致', () {
      final WbCoreLoader loader = WbCoreLoader();
      expect(WbCoreLoader.defaultScriptUrl, 'wb_core.js');
      expect(WbCoreLoader.defaultLoadTimeout, const Duration(seconds: 15));
      expect(loader.scriptUrl, 'wb_core.js');
      expect(loader.loadTimeout, const Duration(seconds: 15));
    });

    test('初始状态为 idle：未加载、不可用、无模块', () {
      final WbCoreLoader loader = WbCoreLoader();
      expect(loader.status, WbCoreStatus.idle);
      expect(loader.isAvailable, isFalse);
      expect(loader.module, isNull);
    });

    test('可自定义 scriptUrl 与 loadTimeout（仅记录，不触发加载）', () {
      final WbCoreLoader loader = WbCoreLoader(
        scriptUrl: 'assets/wb_core.js',
        loadTimeout: const Duration(seconds: 3),
      );
      expect(loader.scriptUrl, 'assets/wb_core.js');
      expect(loader.loadTimeout, const Duration(seconds: 3));
      expect(loader.status, WbCoreStatus.idle);
    });
  });

  group('load 生命周期（非 Web 桩）', () {
    test('load() 不抛异常并以 unavailable 收尾', () async {
      final WbCoreLoader loader = WbCoreLoader();
      final WbCoreStatus status = await loader.load();
      expect(status, WbCoreStatus.unavailable);
      expect(loader.status, WbCoreStatus.unavailable);
      expect(loader.isAvailable, isFalse);
      expect(loader.module, isNull);
    });

    test('load() 幂等：重复调用保持 unavailable', () async {
      final WbCoreLoader loader = WbCoreLoader();
      expect(await loader.load(), WbCoreStatus.unavailable);
      expect(await loader.load(), WbCoreStatus.unavailable);
      expect(loader.status, WbCoreStatus.unavailable);
    });

    test('progress 流产出 0.0 与 1.0 两个进度点', () async {
      final WbCoreLoader loader = WbCoreLoader();
      final List<double> progress = await loader.progress.toList();
      expect(progress, <double>[0.0, 1.0]);
    });

    test('dispose 为 no-op，释放后接口仍可安全调用', () async {
      final WbCoreLoader loader = WbCoreLoader();
      loader.dispose();
      expect(await loader.load(), WbCoreStatus.unavailable);
      expect(await loader.call('wb_version'), isNull);
      expect(loader.cwrap('wb_version'), isNull);
    });
  });

  group('WbCoreStatus 枚举契约', () {
    test('四个状态与稳定 id / 中文 label', () {
      expect(WbCoreStatus.values, hasLength(4));
      expect(WbCoreStatus.idle.id, 'idle');
      expect(WbCoreStatus.idle.label, '未加载');
      expect(WbCoreStatus.loading.id, 'loading');
      expect(WbCoreStatus.loading.label, '加载中');
      expect(WbCoreStatus.ready.id, 'ready');
      expect(WbCoreStatus.ready.label, '已就绪');
      expect(WbCoreStatus.unavailable.id, 'unavailable');
      expect(WbCoreStatus.unavailable.label, '不可用');
    });

    test('isAvailable 仅 ready 为 true', () {
      for (final WbCoreStatus status in WbCoreStatus.values) {
        expect(
          status.isAvailable,
          status == WbCoreStatus.ready,
          reason: '${status.id} 的 isAvailable 判定',
        );
      }
    });
  });

  group('WbCoreService 装配', () {
    test('initialize() 走 unavailable 降级路径并通知监听者', () async {
      final WbCoreService service = WbCoreService();
      addTearDown(service.dispose);
      int notified = 0;
      service.addListener(() => notified += 1);

      expect(service.status, WbCoreStatus.idle);
      await service.initialize();
      expect(service.status, WbCoreStatus.unavailable);
      expect(service.isAvailable, isFalse);
      expect(notified, 1);

      // 幂等：重复初始化状态不变，但仍按实现通知一次。
      await service.initialize();
      expect(service.status, WbCoreStatus.unavailable);
      expect(notified, 2);
    });

    test('ready 路径：注入 fake 加载器后服务透传状态', () async {
      final _FakeLoader fake = _FakeLoader(WbCoreStatus.ready);
      final WbCoreService service = WbCoreService(loader: fake);
      addTearDown(service.dispose);

      int notified = 0;
      service.addListener(() => notified += 1);
      await service.initialize();

      expect(fake.loadCalls, 1);
      expect(service.status, WbCoreStatus.ready);
      expect(service.isAvailable, isTrue);
      expect(notified, 1);
    });

    test('dispose 释放底层加载器', () {
      final _FakeLoader fake = _FakeLoader(WbCoreStatus.unavailable);
      final WbCoreService service = WbCoreService(loader: fake);
      expect(fake.disposeCalls, 0);
      service.dispose();
      expect(fake.disposeCalls, 1);
    });
  });
}

/// 可注入的 fake 加载器：模拟 idle → 目标状态 的加载过程并记录调用次数。
///
/// 仅用于验证 [WbCoreService] 的装配与状态透传（VM 无真实 wasm）。
class _FakeLoader extends WbCoreLoader {
  _FakeLoader(this._next);

  final WbCoreStatus _next;

  WbCoreStatus _current = WbCoreStatus.idle;

  /// `load()` 被调用次数。
  int loadCalls = 0;

  /// `dispose()` 被调用次数。
  int disposeCalls = 0;

  @override
  WbCoreStatus get status => _current;

  @override
  bool get isAvailable => _current.isAvailable;

  @override
  Future<WbCoreStatus> load() async {
    loadCalls += 1;
    _current = _next;
    return _current;
  }

  @override
  void dispose() {
    disposeCalls += 1;
  }
}
