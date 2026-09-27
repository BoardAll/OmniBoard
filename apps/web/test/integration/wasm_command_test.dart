/// apps/web WASM 集成测试（《测试方案设计》§7.3）—— 命令执行代理。
///
/// VM 环境没有真实 wasm，本文件验证 platform/web 暴露的
/// **命令调用接口形状**（`call` / `cwrap` / [WbCoreCallable]）：
/// - 桩：任意名称 / 参数调用恒返回 null 且不抛异常（降级判定依据）；
/// - ready 路径：注入 fake 加载器验证代理转发与返回值通道；
/// - [WbCoreModule.unsupported] 的 `ccall` / `cwrap` 占位行为。
///
/// 命令契约对齐 `core/include/wb/wb.h`（`wb_version` / `wb_create_board` /
/// `wb_execute_command` 等符号名），真实执行由 C++ 侧单测与桌面 FFI
/// 集成测试（apps/desktop/test/integration）覆盖。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

void main() {
  group('call 代理（非 Web 桩）', () {
    test('wb_version 返回 null（降级：无版本可读）', () async {
      final WbCoreLoader loader = WbCoreLoader();
      expect(await loader.call('wb_version'), isNull);
    });

    test('命令类调用携带 JSON 字符串参数同样安全返回 null', () async {
      final WbCoreLoader loader = WbCoreLoader();
      expect(
        await loader.call('wb_create_board', <Object?>['{"name":"集成测试"}']),
        isNull,
      );
      expect(
        await loader.call('wb_execute_command', <Object?>[
          '{"tool":"element.create","params":{"kind":"sticky"}}',
          1,
          2.5,
          true,
          null,
        ]),
        isNull,
      );
    });

    test('文档示例的 isAvailable 守卫语义：不可用时跳过调用', () async {
      final WbCoreLoader loader = WbCoreLoader();
      final WbCoreStatus status = await loader.load();
      Object? version;
      if (status.isAvailable) {
        version = await loader.call('wb_version');
      }
      expect(status, WbCoreStatus.unavailable);
      expect(version, isNull);
    });
  });

  group('cwrap 代理（非 Web 桩）', () {
    test('cwrap 恒返回 null（无函数指针可包装）', () {
      final WbCoreLoader loader = WbCoreLoader();
      expect(loader.cwrap('wb_version'), isNull);
      expect(
        loader.cwrap(
          'wb_create_board',
          returnType: 'number',
          argTypes: <String>['string'],
        ),
        isNull,
      );
    });
  });

  group('ready 路径（注入 fake 加载器）', () {
    test('call 代理转发名称与参数并返回原生结果', () async {
      final _RecordingLoader loader = _RecordingLoader();
      expect(await loader.call('wb_version'), '0.1.0');
      expect(await loader.call('wb_create_board', <Object?>['{}']), 1);
      expect(loader.calls, <String>['wb_version', 'wb_create_board']);
      expect(loader.lastArgs, <Object?>['{}']);
    });

    test('cwrap 返回可调用代理（WbCoreCallable）', () {
      final _RecordingLoader loader = _RecordingLoader();
      final WbCoreCallable? callable = loader.cwrap(
        'wb_version',
        returnType: 'string',
        argTypes: <String>[],
      );
      expect(callable, isNotNull);
      expect(callable!(<Object?>[]), '0.1.0');
    });
  });

  group('WbCoreModule.unsupported 占位', () {
    test('ccall / cwrap 恒 null，utf8ToString 恒空串', () {
      const WbCoreModule module = WbCoreModule.unsupported;
      expect(
        module.ccall('wb_version', 'string', <String>[], <Object?>[]),
        isNull,
      );
      expect(module.cwrap('wb_version', 'string', <String>[]), isNull);
      expect(module.utf8ToString(0), '');
    });
  });
}

/// 记录式 fake 加载器：验证命令代理的转发路径（不执行真实 WASM）。
class _RecordingLoader extends WbCoreLoader {
  /// 收到的调用名称序列。
  final List<String> calls = <String>[];

  /// 最近一次调用的参数列表。
  List<Object?> lastArgs = const <Object?>[];

  @override
  Future<Object?> call(
    String name, [
    List<Object?> args = const <Object?>[],
  ]) async {
    calls.add(name);
    lastArgs = args;
    return switch (name) {
      'wb_version' => '0.1.0',
      'wb_create_board' => 1,
      _ => null,
    };
  }

  @override
  WbCoreCallable? cwrap(
    String name, {
    String? returnType,
    List<String> argTypes = const <String>[],
  }) {
    if (name == 'wb_version') {
      return (List<Object?> args) => '0.1.0';
    }
    return null;
  }
}
