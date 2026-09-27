// FFI 集成测试共用脚手架（《测试方案设计》§7.2）：定位真实 wb_core.dll、
// 加载并初始化引擎，以及"构建产物缺失时优雅跳过"的统一文案。
//
// 并发注意：`flutter test` 会在同一 flutter_tester 进程内的多个 isolate 中
// 并发运行各测试文件，而 wb_core 的引擎状态（场景仓库、board-N/element-N
// 计数、渲染缓存）是进程级共享的。因此测试约定：
// 1. 断言不得依赖具体的 board-1 / page-1 / element-1 编号，一律用正则或
//    相对增量断言；
// 2. 不调用 wb_shutdown（其实现只解绑日志 sink；留存活可避免跨文件并发
//    时的额外干扰，进程退出即释放）。
import 'dart:io';

import 'package:whiteboard_core/wb_core.dart';

/// 相对 apps/desktop 工作目录（flutter test 的 cwd 为包根）的 DLL 候选路径。
const List<String> _relativeCandidates = <String>[
  '../../build/windows-x64/bin/Release/wb_core.dll',
  'build/windows-x64/bin/Release/wb_core.dll',
];

/// 解析本仓库已构建的 `wb_core.dll` 绝对路径；未构建时返回 null。
String? resolveWbCoreDll() {
  for (final String candidate in _relativeCandidates) {
    final File file = File(candidate);
    if (file.existsSync()) {
      return file.absolute.path;
    }
  }
  // 兜底：从当前目录向父级逐层探测（最多 4 层）build 产物。
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 4; i++) {
    final String sep = Platform.pathSeparator;
    final String path = '${dir.path}${sep}build${sep}windows-x64${sep}bin'
        '${sep}Release${sep}wb_core.dll';
    if (File(path).existsSync()) {
      return File(path).absolute.path;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  return null;
}

/// 引擎缺失时的跳过原因（无构建产物的机器优雅跳过而不是失败）。
const String wbCoreMissingSkipReason =
    '真实 wb_core.dll 未构建：跳过 FFI 集成测试'
    '（先构建 build/windows-x64/bin/Release）';

/// 统一的 FFI 集成 skip 理由。
///
/// 普通环境在 dll 缺失时优雅跳过；强校验环境（`WB_REQUIRE_CORE_DLL=1`，
/// 如 CI 的 desktop-tests job）下直接抛出，避免整包静默假绿
/// （CodeReview 高优先级修复，配套 .github/workflows/ci.yml）。
String? ffiIntegrationSkipReason() {
  if (resolveWbCoreDll() != null) {
    return null;
  }
  if ((Platform.environment['WB_REQUIRE_CORE_DLL'] ?? '') == '1') {
    throw StateError(
      'wb_core.dll 未构建，但 WB_REQUIRE_CORE_DLL=1：FFI 集成测试必须真实运行'
      '（请先执行 tools/scripts/build_cpp.ps1）',
    );
  }
  return wbCoreMissingSkipReason;
}

/// 加载并初始化真实引擎（`wb_init('{}')` 必须返回 0）。
WbCoreFfi loadRealCore(String dllPath) {
  final WbCoreFfi ffi = WbCoreFfi.load(overridePath: dllPath);
  final int rc = ffi.init('{}');
  if (rc != 0) {
    throw StateError('wb_init 失败（rc=$rc）：$dllPath');
  }
  return ffi;
}

/// 一次"创建白板 + 读取快照"的探针上下文。
class FfiBoardHandle {
  /// 绑定引擎句柄与白板快照。
  FfiBoardHandle(this.handle, this.board);

  /// 引擎 uint64 句柄。
  final int handle;

  /// 白板快照（含首个页面）。
  final WbBoard board;

  /// 白板 id（形如 `board-N`）。
  String get boardId => board.id;

  /// 首个页面 id（形如 `page-N`）。
  String get pageId => board.pages.first.id;
}

/// 创建白板并返回 [FfiBoardHandle]（多数用例的公共前置）。
FfiBoardHandle createBoardWithPage(WbCoreFfi ffi, String name) {
  final WbBoardService boards = WbBoardService(ffi);
  final int handle = boards.create(name: name);
  return FfiBoardHandle(handle, boards.get(handle));
}
