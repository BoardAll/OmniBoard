import 'builtin/blackboard.dart';
import 'builtin/clean_professional.dart';
import 'builtin/cyberpunk.dart';
import 'builtin/dark_night.dart';
import 'builtin/enterprise.dart';
import 'builtin/greenboard.dart';
import 'builtin/hand_drawn.dart';
import 'builtin/kids.dart';
import 'builtin/minimal.dart';
import 'theme_data.dart';

/// 主题包（一个包可携带多个主题，对应《主题背景》的主题包加载机制）。
class WbThemePack {
  const WbThemePack({
    required this.id,
    required this.name,
    this.version = '1.0.0',
    this.author = '',
    required this.themes,
  });

  final String id;
  final String name;
  final String version;
  final String author;
  final List<WbThemeData> themes;

  /// 按主题 id 在包内查找（未知返回 null）。
  WbThemeData? themeById(String themeId) {
    for (final WbThemeData theme in themes) {
      if (theme.id == themeId) {
        return theme;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'version': version,
        'author': author,
        'themes': themes.map((WbThemeData t) => t.toJson()).toList(),
      };

  factory WbThemePack.fromJson(Map<String, dynamic> json) {
    final Object? rawThemes = json['themes'];
    final List<WbThemeData> themes = <WbThemeData>[];
    if (rawThemes is List) {
      for (final Object? item in rawThemes) {
        if (item is Map) {
          themes.add(WbThemeData.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return WbThemePack(
      id: json['id'] is String ? json['id'] as String : 'custom',
      name: json['name'] is String ? json['name'] as String : '自定义主题包',
      version: json['version'] is String ? json['version'] as String : '1.0.0',
      author: json['author'] is String ? json['author'] as String : '',
      themes: themes,
    );
  }
}

/// 内置主题注册表（9 个内置主题，与 C++ `kThemes` 一一对应）。
abstract final class WbBuiltinThemes {
  /// 默认主题 id。
  static const String defaultId = 'clean-professional';

  static const WbThemeData cleanProfessional = kCleanProfessionalTheme;
  static const WbThemeData darkNight = kDarkNightTheme;
  static const WbThemeData blackboard = kBlackboardTheme;
  static const WbThemeData greenboard = kGreenboardTheme;
  static const WbThemeData minimal = kMinimalTheme;
  static const WbThemeData handDrawn = kHandDrawnTheme;
  static const WbThemeData cyberpunk = kCyberpunkTheme;
  static const WbThemeData kids = kKidsTheme;
  static const WbThemeData enterprise = kEnterpriseTheme;

  /// 全部内置主题（顺序与 C++ `kThemes` 一致）。
  static const List<WbThemeData> all = <WbThemeData>[
    cleanProfessional,
    darkNight,
    blackboard,
    greenboard,
    minimal,
    handDrawn,
    cyberpunk,
    kids,
    enterprise,
  ];

  /// 默认主题（clean-professional）。
  static const WbThemeData defaultTheme = cleanProfessional;

  /// 按 id 查找内置主题（未知返回 null）。
  static WbThemeData? byId(String id) {
    for (final WbThemeData theme in all) {
      if (theme.id == id) {
        return theme;
      }
    }
    return null;
  }

  /// 内置主题包。
  static const WbThemePack pack = WbThemePack(
    id: 'whiteboard.builtin',
    name: '内置主题',
    author: 'Whiteboard',
    themes: all,
  );
}
