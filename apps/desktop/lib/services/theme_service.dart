/// 主题服务：桥接主题管理器与偏好持久化。
library;

import 'package:whiteboard_theme/theme.dart';

/// 主题应用服务。
///
/// 偏好经可选的 [prefsSink]（[WbThemePrefsSink] 窄接口）落盘到设置存储；
/// sink 为 null 时保持纯内存（既有测试与独立预览零影响），对外契约
/// （[select] / [manager]）保持不变。
class WbThemeService {
  WbThemeService({String initialThemeId = '', WbThemePrefsSink? prefsSink})
      : prefsSink = prefsSink,
        manager = WbThemeManager(
          initialThemeId: _resolveInitialThemeId(initialThemeId, prefsSink),
        ) {
    persistedThemeId = prefsSink?.themeId ?? '';
    persistedAppearance = prefsSink?.appearance ?? const WbAppearancePrefs();
    manager.onThemeChanged = _persist;
  }

  /// 主题管理器（ChangeNotifier，供顶层监听）。
  final WbThemeManager manager;

  /// 偏好持久化接纳端（null = 纯内存，不落盘）。
  final WbThemePrefsSink? prefsSink;

  /// 最近一次持久化的主题 id（测试可直接断言）。
  String persistedThemeId = '';

  /// 最近一次保存的外观偏好（测试可直接断言）。
  ///
  /// Wave 3.8 增量：主题 id 之外的设置项（跟随系统 / 图标包 / 字号缩放 /
  /// 无障碍 / 背景联动），字段形状可序列化，经 [prefsSink] 直接落盘。
  WbAppearancePrefs persistedAppearance = const WbAppearancePrefs();

  /// 解析初始主题 id：显式参数优先，其次持久化值，最后 null（默认主题）。
  static String? _resolveInitialThemeId(
    String explicit,
    WbThemePrefsSink? sink,
  ) {
    if (explicit.isNotEmpty) {
      return explicit;
    }
    final String stored = sink?.themeId ?? '';
    return stored.isEmpty ? null : stored;
  }

  /// 当前主题。
  WbThemeData get current => manager.current;

  /// 全部可用主题（9 内置 + 自定义）。
  List<WbThemeData> get available => manager.available;

  /// 切换主题（未知 id 回退默认主题）。
  void select(String themeId) => manager.setTheme(themeId);

  /// 保存外观偏好（内存镜像 + 经 sink 落盘）。
  void saveAppearance(WbAppearancePrefs prefs) {
    persistedAppearance = prefs;
    prefsSink?.appearance = prefs;
  }

  void _persist(String themeId) {
    persistedThemeId = themeId;
    prefsSink?.themeId = themeId;
  }

  void dispose() => manager.dispose();
}

/// 主题偏好持久化接纳端（窄接口，避免服务与存储实现循环依赖）。
///
/// 由 `services/settings_store.dart` 的 `WbSettingsStore` 实现；
/// 主题服务只依赖本接口，不感知具体存储。
abstract interface class WbThemePrefsSink {
  /// 最近保存的主题 id（空串 = 未保存过）。
  String get themeId;

  /// 写入主题 id（实现方负责落盘时机）。
  set themeId(String value);

  /// 最近保存的外观偏好。
  WbAppearancePrefs get appearance;

  /// 写入外观偏好（实现方负责落盘时机）。
  set appearance(WbAppearancePrefs value);
}

/// 外观偏好（主题 id 之外的设置项，Wave 3.8 引入）。
///
/// 对应《主题与背景系统设计》§8.5 设置项表：
/// 跟随系统 / 定时切换 / 图标包 / 字号缩放 / 减少动效 / 减少透明度 /
/// 高对比度 / 背景与背景跟随主题。
class WbAppearancePrefs {
  const WbAppearancePrefs({
    this.followSystem = false,
    this.autoSwitch = false,
    this.iconStyle = 'linear',
    this.fontScale = 1.0,
    this.reduceMotion = false,
    this.reduceTransparency = false,
    this.highContrast = false,
    this.backgroundFollowTheme = true,
    this.backgroundPresetId = defaultBackgroundPresetId,
    this.backgroundCustomColor = '',
    this.backgroundSpacing = 0,
    this.backgroundPatternColor = '',
    this.backgroundOpacity = 1.0,
    this.toolbarStyle = toolbarStyleRadial,
    this.windowMode = windowModeWindow,
    this.shortcutOverrides = const <String, List<String>>{},
  });

  /// 默认背景预设（文档 §8.5：浅灰白板）。
  static const String defaultBackgroundPresetId = 'light-gray';

  /// 工具栏风格：齿轮圆盘（默认，保持既有主设计）。
  static const String toolbarStyleRadial = 'radial';

  /// 工具栏风格：顶部工具面板（`WbCanvasToolPalette`）。
  static const String toolbarStyleTop = 'top';

  /// 窗口模式：常规窗口（默认）。
  static const String windowModeWindow = 'window';

  /// 窗口模式：黑板模式（去标题栏直接全屏）。
  static const String windowModeBlackboard = 'blackboard';

  /// 字号缩放下限（文档 §8.5：80%）。
  static const double minFontScale = 0.8;

  /// 字号缩放上限（文档 §8.5：150%）。
  static const double maxFontScale = 1.5;

  /// 跟随系统深浅色（默认关）。
  final bool followSystem;

  /// 定时切换（时段深浅色切换；运行时调度 Wave 4 接入，当前仅存偏好）。
  final bool autoSwitch;

  /// 图标包 id（见 `whiteboard_icons` 的 `WbIconStyle`，共 5 种）。
  final String iconStyle;

  /// 字号缩放（0.8–1.5）。
  final double fontScale;

  /// 减少动效。
  final bool reduceMotion;

  /// 减少透明度。
  final bool reduceTransparency;

  /// 高对比度。
  final bool highContrast;

  /// 背景跟随主题（文档 §7.2，默认开）。
  final bool backgroundFollowTheme;

  /// 背景预设 id（`WbBackgroundService.builtinPresets` 之一）。
  final String backgroundPresetId;

  /// 自定义背景色（`#RRGGBB`；非空时优先于预设）。
  final String backgroundCustomColor;

  /// 图案间距覆盖（0 = 使用预设值）。
  final int backgroundSpacing;

  /// 图案颜色覆盖（`#RRGGBB`；空串 = 使用预设值）。
  final String backgroundPatternColor;

  /// 背景透明度（0–1，1 = 不透明）。
  final double backgroundOpacity;

  /// 工具栏风格 id（[toolbarStyleRadial] / [toolbarStyleTop]）。
  final String toolbarStyle;

  /// 窗口模式 id（[windowModeWindow] / [windowModeBlackboard]）。
  final String windowMode;

  /// 快捷键覆盖（动作 id → 键位片段，如 `['Ctrl', 'K']`）。空表示全部默认。
  final Map<String, List<String>> shortcutOverrides;

  /// 返回修改指定字段后的副本。
  WbAppearancePrefs copyWith({
    bool? followSystem,
    bool? autoSwitch,
    String? iconStyle,
    double? fontScale,
    bool? reduceMotion,
    bool? reduceTransparency,
    bool? highContrast,
    bool? backgroundFollowTheme,
    String? backgroundPresetId,
    String? backgroundCustomColor,
    int? backgroundSpacing,
    String? backgroundPatternColor,
    double? backgroundOpacity,
    String? toolbarStyle,
    String? windowMode,
    Map<String, List<String>>? shortcutOverrides,
  }) {
    return WbAppearancePrefs(
      followSystem: followSystem ?? this.followSystem,
      autoSwitch: autoSwitch ?? this.autoSwitch,
      iconStyle: iconStyle ?? this.iconStyle,
      fontScale: fontScale ?? this.fontScale,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      reduceTransparency: reduceTransparency ?? this.reduceTransparency,
      highContrast: highContrast ?? this.highContrast,
      backgroundFollowTheme:
          backgroundFollowTheme ?? this.backgroundFollowTheme,
      backgroundPresetId: backgroundPresetId ?? this.backgroundPresetId,
      backgroundCustomColor:
          backgroundCustomColor ?? this.backgroundCustomColor,
      backgroundSpacing: backgroundSpacing ?? this.backgroundSpacing,
      backgroundPatternColor:
          backgroundPatternColor ?? this.backgroundPatternColor,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      toolbarStyle: toolbarStyle ?? this.toolbarStyle,
      windowMode: windowMode ?? this.windowMode,
      shortcutOverrides: shortcutOverrides ?? this.shortcutOverrides,
    );
  }

  /// JSON 形状（Wave 4 持久化 / 跨端传输使用）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'followSystem': followSystem,
        'autoSwitch': autoSwitch,
        'iconStyle': iconStyle,
        'fontScale': fontScale,
        'reduceMotion': reduceMotion,
        'reduceTransparency': reduceTransparency,
        'highContrast': highContrast,
        'backgroundFollowTheme': backgroundFollowTheme,
        'backgroundPresetId': backgroundPresetId,
        'backgroundCustomColor': backgroundCustomColor,
        'backgroundSpacing': backgroundSpacing,
        'backgroundPatternColor': backgroundPatternColor,
        'backgroundOpacity': backgroundOpacity,
        'toolbarStyle': toolbarStyle,
        'windowMode': windowMode,
        if (shortcutOverrides.isNotEmpty)
          'shortcutOverrides': <String, List<String>>{
            for (final MapEntry<String, List<String>> entry
                in shortcutOverrides.entries)
              entry.key: List<String>.of(entry.value),
          },
      };

  /// 从 JSON 恢复（缺省字段使用默认值；字号缩放自动夹取边界）。
  factory WbAppearancePrefs.fromJson(Map<String, dynamic> json) {
    bool readBool(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    double readDouble(String key, double fallback) =>
        json[key] is num ? (json[key] as num).toDouble() : fallback;
    String readString(String key, String fallback) =>
        json[key] is String ? json[key] as String : fallback;
    int readInt(String key, int fallback) =>
        json[key] is num ? (json[key] as num).round() : fallback;

    return WbAppearancePrefs(
      followSystem: readBool('followSystem', false),
      autoSwitch: readBool('autoSwitch', false),
      iconStyle: readString('iconStyle', 'linear'),
      fontScale: readDouble('fontScale', 1.0).clamp(minFontScale, maxFontScale),
      reduceMotion: readBool('reduceMotion', false),
      reduceTransparency: readBool('reduceTransparency', false),
      highContrast: readBool('highContrast', false),
      backgroundFollowTheme: readBool('backgroundFollowTheme', true),
      backgroundPresetId: readString(
        'backgroundPresetId',
        defaultBackgroundPresetId,
      ),
      backgroundCustomColor: readString('backgroundCustomColor', ''),
      backgroundSpacing: readInt('backgroundSpacing', 0),
      backgroundPatternColor: readString('backgroundPatternColor', ''),
      backgroundOpacity: readDouble('backgroundOpacity', 1.0).clamp(0.0, 1.0),
      toolbarStyle: readString('toolbarStyle', toolbarStyleRadial),
      windowMode: readString('windowMode', windowModeWindow),
      shortcutOverrides: _readShortcutOverrides(json['shortcutOverrides']),
    );
  }

  static Map<String, List<String>> _readShortcutOverrides(Object? raw) {
    if (raw is! Map) {
      return const <String, List<String>>{};
    }
    final Map<String, List<String>> overrides = <String, List<String>>{};
    raw.forEach((Object? key, Object? value) {
      if (key is! String || value is! List) {
        return;
      }
      final List<String> keys = <String>[
        for (final Object? part in value)
          if (part is String && part.isNotEmpty) part,
      ];
      if (keys.isNotEmpty) {
        overrides[key] = List<String>.unmodifiable(keys);
      }
    });
    return Map<String, List<String>>.unmodifiable(overrides);
  }

  @override
  bool operator ==(Object other) =>
      other is WbAppearancePrefs &&
      other.followSystem == followSystem &&
      other.autoSwitch == autoSwitch &&
      other.iconStyle == iconStyle &&
      other.fontScale == fontScale &&
      other.reduceMotion == reduceMotion &&
      other.reduceTransparency == reduceTransparency &&
      other.highContrast == highContrast &&
      other.backgroundFollowTheme == backgroundFollowTheme &&
      other.backgroundPresetId == backgroundPresetId &&
      other.backgroundCustomColor == backgroundCustomColor &&
      other.backgroundSpacing == backgroundSpacing &&
      other.backgroundPatternColor == backgroundPatternColor &&
      other.backgroundOpacity == backgroundOpacity &&
      other.toolbarStyle == toolbarStyle &&
      other.windowMode == windowMode &&
      _sameOverrides(other.shortcutOverrides, shortcutOverrides);

  @override
  int get hashCode => Object.hash(
        followSystem,
        autoSwitch,
        iconStyle,
        fontScale,
        reduceMotion,
        reduceTransparency,
        highContrast,
        backgroundFollowTheme,
        backgroundPresetId,
        backgroundCustomColor,
        backgroundSpacing,
        backgroundPatternColor,
        backgroundOpacity,
        toolbarStyle,
        windowMode,
        Object.hashAll(
          shortcutOverrides.entries.map(
            (MapEntry<String, List<String>> entry) =>
                Object.hash(entry.key, Object.hashAll(entry.value)),
          ),
        ),
      );

  static bool _sameOverrides(
    Map<String, List<String>> a,
    Map<String, List<String>> b,
  ) {
    if (a.length != b.length) {
      return false;
    }
    for (final MapEntry<String, List<String>> entry in a.entries) {
      final List<String>? other = b[entry.key];
      if (other == null || other.length != entry.value.length) {
        return false;
      }
      for (var i = 0; i < other.length; i++) {
        if (other[i] != entry.value[i]) {
          return false;
        }
      }
    }
    return true;
  }
}
