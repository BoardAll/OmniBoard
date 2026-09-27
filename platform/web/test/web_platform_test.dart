/// platform/web 的 VM 安全测试（非 Web 环境降级路径）。
///
/// 在 Windows VM（`flutter test`，无浏览器运行时）上验证：
/// - [WbCoreLoader] 返回 [WbCoreStatus.unavailable] 且不抛异常；
/// - `call` / `cwrap` 代理在不可用时返回 null；
/// - [WbWindowPlugin] 能力查询为 false、窗口调用 no-op；
/// - [WbCoreStatus] / [WebWindowCapabilities] 的纯逻辑。
///
/// Web 目标的真实加载路径（script 注入 / Promise 实例化）依赖浏览器，
/// 由 Wave 4 的 WASM 产物 + 浏览器集成测试覆盖。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

void main() {
  group('WbCoreStatus', () {
    test('仅 ready 视为可用', () {
      expect(WbCoreStatus.ready.isAvailable, isTrue);
      const List<WbCoreStatus> inactive = <WbCoreStatus>[
        WbCoreStatus.idle,
        WbCoreStatus.loading,
        WbCoreStatus.unavailable,
      ];
      for (final WbCoreStatus status in inactive) {
        expect(status.isAvailable, isFalse, reason: '${status.id} 不应可用');
      }
    });

    test('id/label 稳定非空', () {
      for (final WbCoreStatus status in WbCoreStatus.values) {
        expect(status.id, isNotEmpty);
        expect(status.label, isNotEmpty);
      }
    });
  });

  group('WbCoreLoader（非 Web 环境）', () {
    test('load() 返回 unavailable 且不抛异常', () async {
      final WbCoreLoader loader = WbCoreLoader();
      addTearDown(loader.dispose);

      final WbCoreStatus status = await loader.load();

      expect(status, WbCoreStatus.unavailable);
      expect(loader.status, WbCoreStatus.unavailable);
      expect(loader.isAvailable, isFalse);
      expect(loader.module, isNull);
    });

    test('load() 重复调用幂等（结果一致）', () async {
      final WbCoreLoader loader = WbCoreLoader();
      addTearDown(loader.dispose);

      final WbCoreStatus first = await loader.load();
      final WbCoreStatus second = await loader.load();

      expect(first, WbCoreStatus.unavailable);
      expect(second, WbCoreStatus.unavailable);
    });

    test('call() 在不可用时返回 null（不抛异常）', () async {
      final WbCoreLoader loader = WbCoreLoader();
      addTearDown(loader.dispose);
      await loader.load();

      expect(await loader.call('wb_version'), isNull);
      expect(await loader.call('wb_create_board', <Object?>['{}']), isNull);
    });

    test('cwrap() 在不可用时返回 null', () async {
      final WbCoreLoader loader = WbCoreLoader();
      addTearDown(loader.dispose);
      await loader.load();

      expect(
        loader.cwrap('wb_version', returnType: 'number'),
        isNull,
      );
    });

    test('progress 流可监听且产出 0.0 → 1.0', () async {
      final WbCoreLoader loader = WbCoreLoader();
      addTearDown(loader.dispose);

      final List<double> values = await loader.progress.take(2).toList();

      expect(values, <double>[0.0, 1.0]);
    });

    test('自定义 scriptUrl / loadTimeout 不影响降级结果', () async {
      final WbCoreLoader loader = WbCoreLoader(
        scriptUrl: 'https://cdn.example.com/wb_core.js',
        loadTimeout: const Duration(seconds: 1),
      );
      addTearDown(loader.dispose);

      expect(await loader.load(), WbCoreStatus.unavailable);
      expect(loader.scriptUrl, 'https://cdn.example.com/wb_core.js');
    });
  });

  group('WebWindowPlugin（非 Web 环境）', () {
    test('实现统一窗口接口 WbWindowPlugin', () {
      final WebWindowPlugin plugin = WebWindowPlugin();
      expect(plugin, isA<WbWindowPlugin>());
    });

    test('能力查询全部为 false', () {
      final WebWindowPlugin plugin = WebWindowPlugin();

      final WebWindowCapabilities capabilities = plugin.capabilities;

      expect(capabilities.fullscreen, isFalse);
      expect(capabilities.transparent, isFalse);
      expect(capabilities.alwaysOnTop, isFalse);
      expect(capabilities.ignoreMouseEvents, isFalse);
      expect(capabilities.position, isFalse);
      expect(capabilities.size, isFalse);
      expect(plugin.supportsFullscreen, isFalse);
    });

    test('窗口调用 no-op 且 Future 正常完成', () async {
      final WebWindowPlugin plugin = WebWindowPlugin();

      await plugin.setTransparent(true);
      await plugin.setAlwaysOnTop(true);
      await plugin.setIgnoreMouseEvents(true, forward: true);
      await plugin.setFullscreen(true);
      await plugin.setPosition(10, 20);
      await plugin.setSize(1280, 800);
    });

    test('WebWindowCapabilities.none 与预设常量', () {
      expect(WebWindowCapabilities.none.fullscreen, isFalse);
      expect(WebWindowCapabilities.browser.fullscreen, isTrue);
      expect(WebWindowCapabilities.browser.transparent, isFalse);
    });
  });

  group('插件入口', () {
    test('WhiteboardWebPlatform 类型可用（registerWith 由生成代码调用）', () {
      expect(WhiteboardWebPlatform, isNotNull);
    });
  });
}
