/// FFI 服务：懒加载核心引擎并聚合各领域子服务。
library;

import 'dart:io';

import 'package:whiteboard_core/wb_core.dart';

/// 核心引擎 FFI 聚合服务。
///
/// 加载失败（DLL 缺失等）不会中断应用：[isAvailable] 为 false 时
/// 上层进入**演示模式**（无引擎的开发/测试环境），所有子服务 getter
/// 在引擎不可用时抛出 [StateError]。
class WbFfiService {
  WbFfiService({List<String>? candidatePaths})
      : _candidatePaths = candidatePaths ?? defaultCandidatePaths;

  /// 默认候选库路径（按顺序尝试，首个成功者胜出）。
  static List<String> get defaultCandidatePaths {
    if (Platform.isWindows) {
      return <String>[
        'wb_core.dll',
        '../../build/windows-x64/bin/Release/wb_core.dll',
        'build/windows-x64/bin/Release/wb_core.dll',
      ];
    }
    if (Platform.isMacOS) {
      return <String>[
        'libwb_core.dylib',
        '../../build/macos-arm64/bin/Release/libwb_core.dylib',
      ];
    }
    return <String>[
      'libwb_core.so',
      '../../build/linux-x64/bin/Release/libwb_core.so',
    ];
  }

  final List<String> _candidatePaths;
  WbCoreFfi? _ffi;
  Object? _error;
  String _loadedFrom = '';

  /// 已加载的 FFI 句柄（未加载返回 null）。
  WbCoreFfi? get ffi => _ffi;

  /// 最近一次加载失败原因（加载成功后清空）。
  Object? get error => _error;

  /// 引擎是否可用。
  bool get isAvailable => _ffi != null;

  /// 实际加载成功的路径（空串表示尚未加载）。
  String get loadedFrom => _loadedFrom;

  /// 依次尝试候选路径加载并 `wb_init`；全部失败时仅记录 [error]。
  void initialize() {
    for (final String path in _candidatePaths) {
      try {
        final WbCoreFfi loaded = WbCoreFfi.load(overridePath: path);
        loaded.init('{}');
        _ffi = loaded;
        _loadedFrom = path;
        _error = null;
        return;
      } catch (e) {
        _ffi = null;
        _error = e;
      }
    }
  }

  /// 释放引擎（幂等；未加载时为 no-op）。
  void dispose() {
    try {
      _ffi?.shutdown();
    } catch (_) {
      // 忽略关闭期异常（进程即将退出）。
    }
    _ffi = null;
    _loadedFrom = '';
  }

  // ---- 子服务（引擎不可用时抛 StateError） ----

  WbBoardService get board => WbBoardService(_require());
  WbElementService get element => WbElementService(_require());
  WbPageService get page => WbPageService(_require());
  WbRenderService get render => WbRenderService(_require());
  WbAiService get ai => WbAiService(_require());
  WbThemeService get theme => WbThemeService(_require());
  WbToolService get tool => WbToolService(_require());
  WbBackgroundService get background => WbBackgroundService(_require());

  WbSyncService get sync => WbSyncService(_require());

  WbCrdtService get crdt => WbCrdtService(_require());

  WbCoreFfi _require() {
    final WbCoreFfi? ffi = _ffi;
    if (ffi == null) {
      throw StateError('wb_core 未加载（${_error ?? '未知原因'}）');
    }
    return ffi;
  }
}
