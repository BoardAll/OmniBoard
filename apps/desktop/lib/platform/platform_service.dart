/// 平台能力探测服务。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// 平台能力探测（无状态）。
abstract final class WbPlatformService {
  /// 是否运行于 Web。
  static bool get isWeb => kIsWeb;

  /// 是否桌面平台（Windows / macOS / Linux）。
  static bool get isDesktop =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 是否支持透明批注模式（仅桌面）。
  static bool get supportsTransparentOverlay => isDesktop;

  /// 是否支持窗口级功能（置顶 / 全屏 / 托盘）。
  static bool get supportsWindowControls => isDesktop;

  /// 平台显示名（中文，UI 展示用）。
  static String get platformName {
    if (kIsWeb) {
      return 'Web';
    }
    if (Platform.isWindows) {
      return 'Windows';
    }
    if (Platform.isMacOS) {
      return 'macOS';
    }
    if (Platform.isLinux) {
      return 'Linux';
    }
    if (Platform.isAndroid) {
      return 'Android';
    }
    if (Platform.isIOS) {
      return 'iOS';
    }
    return '未知平台';
  }
}
