/// 本地存储：应用数据目录下的小型 JSON 文件读写。
///
/// 设置持久化（`settings.json`）与白板文件默认目录解析的公共底座；
/// 全部方法同步 IO 且失败静默（返回 null / false）—— 持久化不可用时
/// 不影响应用其余功能（骨架注释「Wave 4 接持久化」的落地实现）。
library;

import 'dart:convert';
import 'dart:io';

/// 本地 JSON 文件存储。
///
/// 基础目录解析顺序：
/// - 显式注入 [baseDirOverride]（测试用临时目录，优先）；
/// - Windows：`%APPDATA%\Whiteboard`（回退 `%USERPROFILE%\.whiteboard`）；
/// - 其它平台：`$HOME/.whiteboard`。
class WbLocalStore {
  WbLocalStore({String? baseDirOverride}) : _baseDirOverride = baseDirOverride;

  final String? _baseDirOverride;

  /// 基础目录（无法解析时返回空串）。
  String get baseDir {
    final String? override = _baseDirOverride;
    if (override != null && override.isNotEmpty) {
      return override;
    }
    if (Platform.isWindows) {
      final String appData = Platform.environment['APPDATA'] ?? '';
      if (appData.isNotEmpty) {
        return '$appData\\Whiteboard';
      }
      final String profile = Platform.environment['USERPROFILE'] ?? '';
      if (profile.isNotEmpty) {
        return '$profile\\.whiteboard';
      }
      return '';
    }
    final String home = Platform.environment['HOME'] ?? '';
    return home.isEmpty ? '' : '$home/.whiteboard';
  }

  /// 指定文件的绝对路径（基础目录不可解析时返回空串）。
  String pathFor(String fileName) {
    final String dir = baseDir;
    if (dir.isEmpty || fileName.isEmpty) {
      return '';
    }
    final String separator = Platform.isWindows ? '\\' : '/';
    return '$dir$separator$fileName';
  }

  /// 读取 JSON 对象（文件缺失 / 坏 JSON / IO 失败返回 null）。
  Map<String, dynamic>? readJson(String fileName) {
    final String path = pathFor(fileName);
    if (path.isEmpty) {
      return null;
    }
    try {
      final File file = File(path);
      if (!file.existsSync()) {
        return null;
      }
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (_) {
      // 坏 JSON / 权限错误：视为无持久化数据。
      return null;
    }
  }

  /// 写入 JSON 对象（目录自动创建；失败返回 false）。
  bool writeJson(String fileName, Map<String, dynamic> data) {
    final String path = pathFor(fileName);
    if (path.isEmpty) {
      return false;
    }
    try {
      final File file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(data), flush: true);
      return true;
    } catch (_) {
      // IO 失败：静默（内存态仍完整）。
      return false;
    }
  }

  /// 确保目录存在（用于保存前预创建默认目录；失败静默）。
  bool ensureDir(String dir) {
    if (dir.isEmpty) {
      return false;
    }
    try {
      Directory(dir).createSync(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}
