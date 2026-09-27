/// Linux 插件动态库的定位与加载（dart:ffi）。
///
/// 构建产物位置：
///
///   - 本地构建目录：`build/linux/x64/<mode>/plugins/whiteboard_linux/libwhiteboard_linux.so`
///     （`linux/CMakeLists.txt` 的 CMake 目标输出，目标名即包名）；
///   - Flutter Linux 应用打包后位于 bundle 的 `lib/` 目录
///     （应用 rpath 为 `$ORIGIN/lib`，因此以文件名 dlopen 即可命中）。
///
/// 候选加载名（见 [wbLinuxLibraryCandidates]）：
///
///   - `libwhiteboard_linux.so` —— 当前 CMake 目标输出名；
///   - `libwhiteboard_linux_plugin.so` —— 兼容 Flutter 插件模板的
///     `<包名>_plugin` 命名（历史 / 自定义构建配置）。
///
/// [tryLoad] 对任何失败（库缺失、非 Linux 平台、路径不可用）返回 null，
/// 绝不抛异常；调用方据此走「库缺失降级」路径。
library;

import 'dart:ffi';
import 'dart:io' show Platform;

/// 候选动态库文件名（按尝试顺序）。
const List<String> wbLinuxLibraryCandidates = <String>[
  'libwhiteboard_linux.so',
  'libwhiteboard_linux_plugin.so',
];

/// [DynamicLibrary] 的轻量包装：集中加载策略与符号查找。
///
/// 通过 [tryLoad] 构造；返回 null 表示库不可用。测试可通过
/// [WbNativeLibrary.fromDynamicLibrary] 注入自定义句柄。
class WbNativeLibrary {
  WbNativeLibrary._(this.library);

  /// 包装一个已打开的动态库（测试或自定义宿主注入用）。
  factory WbNativeLibrary.fromDynamicLibrary(DynamicLibrary library) =
      WbNativeLibrary._;

  /// 底层动态库句柄。
  final DynamicLibrary library;

  /// 尝试加载 Linux 插件动态库。
  ///
  /// [overridePath] 非空时仅尝试该路径（测试 / 自定义打包布局）。
  /// 任何失败都返回 null（绝不抛异常），表示调用方应静默降级：
  /// 方法 no-op、查询返回 false/null、事件流为空。
  static WbNativeLibrary? tryLoad({String? overridePath}) {
    if (overridePath != null) {
      try {
        return WbNativeLibrary._(DynamicLibrary.open(overridePath));
      } catch (_) {
        // 指定路径不可用。
        return null;
      }
    }
    if (!Platform.isLinux) {
      // 非 Linux 平台（例如 Windows 单元测试环境）不存在该 .so。
      return null;
    }
    for (final String candidate in wbLinuxLibraryCandidates) {
      try {
        return WbNativeLibrary._(DynamicLibrary.open(candidate));
      } catch (_) {
        // 当前候选名不可用：继续尝试下一个。
      }
    }
    return null;
  }
}
