// §7.2 FFI 集成（真实 wb_core.dll）：初始化 / 版本 / 句柄生命周期 / 降级。
//
// 该文件必须真实加载 build/windows-x64/bin/Release/wb_core.dll；产物缺失时
// 以 skip 原因优雅跳过；缺失且 WB_REQUIRE_CORE_DLL=1 时硬失败
// （见 support/ffi_support.dart 的 ffiIntegrationSkipReason）。
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_core/wb_core.dart';

import 'support/ffi_support.dart';

void main() {
  final String? dllPath = resolveWbCoreDll();
  final String? skipReason = ffiIntegrationSkipReason();

  group('FFI 初始化（真实引擎）', () {
    late WbCoreFfi ffi;

    setUpAll(() {
      if (dllPath != null) {
        ffi = loadRealCore(dllPath);
      }
    });

    test('版本字符串为 wb.h 约定值且符合语义化版本', () {
      expect(ffi.versionString(), '1.0.0');
      expect(ffi.versionString(), matches(RegExp(r'^\d+\.\d+\.\d+$')));
    }, skip: skipReason);

    test('重复初始化幂等（多次 init 均返回 0）', () {
      expect(ffi.init('{}'), 0);
      expect(ffi.init('{"logLevel":"error"}'), 0);
      expect(ffi.init('{"logLevel":"info"}'), 0); // 还原共享进程的日志级别
    }, skip: skipReason);

    test('非法配置返回 1，且不破坏已初始化的引擎', () {
      expect(ffi.init('{definitely not json'), 1);
      expect(ffi.versionString(), '1.0.0');
      expect(ffi.init('{}'), 0);
    }, skip: skipReason);

    test('创建 / 读取 / 销毁白板与首个页面', () {
      final WbBoardService boards = WbBoardService(ffi);
      final FfiBoardHandle probe = createBoardWithPage(ffi, 'FFI 初始化用例');

      expect(probe.handle, greaterThan(0));
      expect(probe.boardId, matches(RegExp(r'^board-\d+$')));
      expect(probe.board.name, 'FFI 初始化用例');
      expect(probe.board.handle, probe.handle);
      expect(probe.board.pages, isNotEmpty);
      expect(probe.pageId, matches(RegExp(r'^page-\d+$')));

      boards.destroy(probe.handle);
      expect(
        () => boards.get(probe.handle),
        throwsA(
          isA<WbCoreException>()
              .having((WbCoreException e) => e.code, 'code', 'NotFound'),
        ),
      );
    }, skip: skipReason);
  });

  test('缺失动态库路径时 load 抛出 ArgumentError（优雅降级入口）', () {
    expect(
      () => WbCoreFfi.load(overridePath: '__wb_missing__.dll'),
      throwsA(isA<ArgumentError>()),
    );
  });
}
