/// 主题状态：包装主题服务为可监听状态。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_core/wb_core.dart' hide WbThemeService;
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../services/theme_service.dart';

/// 主题状态（ChangeNotifier），供 `ChangeNotifierProvider` 挂载。
///
/// [flutterThemeData] 直接交给 `MaterialApp.theme`。
///
/// Wave 3.8 增量扩展：外观偏好（跟随系统 / 图标包 / 字号缩放 / 无障碍 /
/// 背景联动）。全部为**新增成员**；[followSystem] 默认关，既有成员
/// （[current] / [available] / [select] / [flutterThemeData]）语义不变。
class WbThemeState extends ChangeNotifier {
  WbThemeState({String initialThemeId = '', WbThemePrefsSink? store})
      : service = WbThemeService(
          initialThemeId: initialThemeId,
          prefsSink: store,
        ) {
    _appearance = service.persistedAppearance;
    service.manager.addListener(_onChanged);
  }

  /// 底层主题服务。
  final WbThemeService service;

  WbAppearancePrefs _appearance = const WbAppearancePrefs();
  Brightness _platformBrightness = Brightness.light;

  /// 当前主题。
  WbThemeData get current => service.current;

  /// 全部可用主题。
  List<WbThemeData> get available => service.available;

  /// 系统平台亮度（由宿主壳层 / 设置页上报，默认亮色）。
  Brightness get platformBrightness => _platformBrightness;

  /// 当前生效主题：跟随系统开启时按 [platformBrightness] 切换深浅。
  WbThemeData get effectiveTheme =>
      resolveEffectiveTheme(platformBrightness: _platformBrightness);

  /// 按指定系统亮度计算生效主题（纯函数，便于预览与测试）。
  ///
  /// 跟随系统关闭时返回 [current]；开启且与当前深浅不一致时，取
  /// [available] 中第一个同深浅主题（暗色 → 暗夜等，文档 §8.5）。
  WbThemeData resolveEffectiveTheme({required Brightness platformBrightness}) {
    if (!_appearance.followSystem) {
      return current;
    }
    final bool systemDark = platformBrightness == Brightness.dark;
    if (current.dark == systemDark) {
      return current;
    }
    for (final WbThemeData theme in available) {
      if (theme.dark == systemDark) {
        return theme;
      }
    }
    return current;
  }

  /// 当前主题对应的 Flutter ThemeData（跟随系统时使用 [effectiveTheme]）。
  ThemeData get flutterThemeData => effectiveTheme.toFlutterThemeData();

  /// 上报系统亮度（宿主壳层 / 设置页调用；值未变化时忽略）。
  void updatePlatformBrightness(Brightness brightness) {
    if (_platformBrightness == brightness) {
      return;
    }
    _platformBrightness = brightness;
    notifyListeners();
  }

  /// 切换主题（未知 id 回退默认主题）；背景跟随开启时同步联动背景。
  void select(String themeId) => service.select(themeId);

  // ---------------------------------------------------------------------------
  // Wave 3.8 增量扩展：外观偏好（主题 id 之外）。
  // ---------------------------------------------------------------------------

  /// 外观偏好快照。
  WbAppearancePrefs get appearance => _appearance;

  /// 是否跟随系统深浅色。
  bool get followSystem => _appearance.followSystem;

  /// 是否定时切换（运行时调度 Wave 4 接入）。
  bool get autoSwitch => _appearance.autoSwitch;

  /// 图标包 id（`WbIconStyle.id`）。
  String get iconStyleId => _appearance.iconStyle;

  /// 图标包（`whiteboard_icons` 的 5 种风格）。
  WbIconStyle get iconStyle => WbIconStyle.fromId(_appearance.iconStyle);

  /// 字号缩放（0.8–1.5）。
  double get fontScale => _appearance.fontScale;

  /// 减少动效开关。
  bool get reduceMotion => _appearance.reduceMotion;

  /// 减少透明度开关。
  bool get reduceTransparency => _appearance.reduceTransparency;

  /// 高对比度开关。
  bool get highContrast => _appearance.highContrast;

  /// 背景是否跟随主题。
  bool get backgroundFollowTheme => _appearance.backgroundFollowTheme;

  /// 当前背景预设 id。
  String get backgroundPresetId => _appearance.backgroundPresetId;

  /// 自定义背景色（`#RRGGBB`；空串 = 使用预设）。
  String get backgroundCustomColor => _appearance.backgroundCustomColor;

  /// 图案间距覆盖（0 = 预设值）。
  int get backgroundSpacing => _appearance.backgroundSpacing;

  /// 图案颜色覆盖（`#RRGGBB`；空串 = 预设值）。
  String get backgroundPatternColor => _appearance.backgroundPatternColor;

  /// 背景透明度（0–1）。
  double get backgroundOpacity => _appearance.backgroundOpacity;

  /// 设置跟随系统深浅色。
  void setFollowSystem(bool value) =>
      _updateAppearance(_appearance.copyWith(followSystem: value));

  /// 设置定时切换（仅存偏好，调度器 Wave 4 接入）。
  void setAutoSwitch(bool value) =>
      _updateAppearance(_appearance.copyWith(autoSwitch: value));

  /// 设置图标包（未知 id 回退线性）。
  void setIconStyle(String styleId) => _updateAppearance(
        _appearance.copyWith(iconStyle: WbIconStyle.fromId(styleId).id),
      );

  /// 设置字号缩放（自动夹取 0.8–1.5）。
  void setFontScale(double scale) => _updateAppearance(
        _appearance.copyWith(
          fontScale: scale.clamp(
            WbAppearancePrefs.minFontScale,
            WbAppearancePrefs.maxFontScale,
          ),
        ),
      );

  /// 设置减少动效。
  void setReduceMotion(bool value) =>
      _updateAppearance(_appearance.copyWith(reduceMotion: value));

  /// 设置减少透明度。
  void setReduceTransparency(bool value) =>
      _updateAppearance(_appearance.copyWith(reduceTransparency: value));

  /// 设置高对比度。
  void setHighContrast(bool value) =>
      _updateAppearance(_appearance.copyWith(highContrast: value));

  /// 一次性应用外观偏好（设置页「保存」入口）。
  ///
  /// 与逐项 setter 等价但只通知一次：写入偏好 → 持久化 → 通知；
  /// 值未变化时为幂等。背景联动由调用方按草稿语义处理：设置页
  /// 切换主题时已将草稿背景同步为该主题默认（见 [defaultBackgroundFor]），
  /// 此处不再强制同步，避免覆盖用户显式选择的自定义色 / 预设。
  void applyAppearance(WbAppearancePrefs prefs) {
    if (_appearance == prefs) {
      return;
    }
    _appearance = prefs;
    service.saveAppearance(_appearance);
    notifyListeners();
  }

  /// 设置背景是否跟随主题；开启时立即同步为当前主题默认背景。
  void setBackgroundFollowTheme(bool value) {
    if (!value && !_appearance.backgroundFollowTheme) {
      return;
    }
    _appearance = _appearance.copyWith(backgroundFollowTheme: value);
    if (value) {
      _syncBackgroundWithTheme();
    }
    service.saveAppearance(_appearance);
    notifyListeners();
  }

  /// 选择背景预设（清除自定义色）。
  void selectBackgroundPreset(String presetId) => _updateAppearance(
        _appearance.copyWith(
          backgroundPresetId: presetId,
          backgroundCustomColor: '',
        ),
      );

  /// 选择自定义背景色（`#RRGGBB`，优先于预设）。
  void selectBackgroundColor(Color color) => _updateAppearance(
        _appearance.copyWith(
          backgroundCustomColor: WbColorUtils.toHex(color),
        ),
      );

  /// 设置图案间距覆盖（0 = 预设；夹取 0–120）。
  void setBackgroundSpacing(int spacing) => _updateAppearance(
        _appearance.copyWith(backgroundSpacing: spacing.clamp(0, 120)),
      );

  /// 设置图案颜色覆盖。
  void setBackgroundPatternColor(Color color) => _updateAppearance(
        _appearance.copyWith(
          backgroundPatternColor: WbColorUtils.toHex(color),
        ),
      );

  /// 设置背景透明度（夹取 0–1）。
  void setBackgroundOpacity(double opacity) => _updateAppearance(
        _appearance.copyWith(backgroundOpacity: opacity.clamp(0.0, 1.0)),
      );

  /// 动画时长适配：减少动效开启时归零（供本包 UI 消费）。
  Duration motion(Duration duration) =>
      _appearance.reduceMotion ? Duration.zero : duration;

  /// 当前外观设置解析出的背景对象（对齐 background 域存储形态）。
  ///
  /// - 关闭 [backgroundFollowTheme] 只停止主题联动，不阻止手动应用；
  /// - 自定义色非空时输出纯色对象（id = `custom`）；
  /// - 否则输出预设对象，并套用间距 / 图案色 / 透明度覆盖
  ///   （仅在偏离预设时写入，保持默认输出与 `PresetToJson` 一致）。
  Map<String, dynamic>? get backgroundJson => backgroundJsonOf(_appearance);

  /// 按任意外观偏好快照解析背景对象（设置页草稿预览 / 应用共用）。
  static Map<String, dynamic>? backgroundJsonOf(WbAppearancePrefs prefs) {
    if (prefs.backgroundCustomColor.isNotEmpty) {
      final Color color = WbColorUtils.fromHex(
        prefs.backgroundCustomColor,
        fallback: const Color(0xFFFFFFFF),
      );
      return <String, dynamic>{
        'id': 'custom',
        'name': '自定义背景',
        'pattern': 'solid',
        'baseColor': prefs.backgroundCustomColor,
        'patternColor': '',
        'spacing': 0,
        'dark': !WbColorUtils.isLight(color),
        'custom': true,
      };
    }
    final WbBackgroundPreset? preset =
        WbBackgroundService.presetById(prefs.backgroundPresetId);
    if (preset == null) {
      return null;
    }
    final Map<String, dynamic> json =
        Map<String, dynamic>.of(preset.toBackgroundJson());
    if (preset.type != 'solid') {
      if (prefs.backgroundSpacing > 0) {
        json['spacing'] = prefs.backgroundSpacing;
      }
      if (prefs.backgroundPatternColor.isNotEmpty) {
        json['patternColor'] = prefs.backgroundPatternColor;
      }
    }
    if (prefs.backgroundOpacity < 1) {
      json['opacity'] = prefs.backgroundOpacity;
    }
    return json;
  }

  /// 主题默认背景预设（文档 §7.1 联动规则）。
  static String defaultBackgroundFor(String themeId) => switch (themeId) {
        'dark-night' => 'dark-dot',
        'blackboard' => 'blackboard',
        'greenboard' => 'greenboard',
        'minimal' => 'whiteboard',
        'hand-drawn' => 'cream',
        'cyber' => 'dark-grid',
        'kids' => 'cream',
        _ => WbAppearancePrefs.defaultBackgroundPresetId,
      };

  /// 导入主题包（注册包内全部主题并应用第一个，文档 §8.3）。
  void importPack(WbThemePack pack) => service.manager.registerPack(pack);

  /// 导出当前主题为 JSON 字符串（文档 §8.4；文件保存待平台通道）。
  String exportThemeJson({bool pretty = true}) =>
      WbThemeLoader.serialize(current, pretty: pretty);

  void _syncBackgroundWithTheme() {
    if (!_appearance.backgroundFollowTheme) {
      return;
    }
    final String presetId = defaultBackgroundFor(current.id);
    if (_appearance.backgroundPresetId == presetId &&
        _appearance.backgroundCustomColor.isEmpty) {
      return;
    }
    _appearance = _appearance.copyWith(
      backgroundPresetId: presetId,
      backgroundCustomColor: '',
    );
    service.saveAppearance(_appearance);
  }

  void _updateAppearance(WbAppearancePrefs next) {
    if (_appearance == next) {
      return;
    }
    _appearance = next;
    service.saveAppearance(next);
    notifyListeners();
  }

  void _onChanged() {
    _syncBackgroundWithTheme();
    notifyListeners();
  }

  @override
  void dispose() {
    service.manager.removeListener(_onChanged);
    service.dispose();
    super.dispose();
  }
}
