/// 设置存储：应用级设置（主题 / 外观 / AI / 协作 / 最近白板）的持久化。
///
/// 包装 [WbLocalStore]（`%APPDATA%\Whiteboard\settings.json`），惰性加载 +
/// 字段级写回（每次写入整文件合并输出）；实现 [WbThemePrefsSink] 供主题
/// 服务直接落盘（窄接口避免 services 间循环依赖）。
///
/// 注意：AI 密钥以明文写入本地配置文件（用户已确认接受；仅本机读取）。
library;

import 'package:whiteboard_ai/ai_client.dart';
import 'package:whiteboard_canvas/context_editors/flow_components.dart';
import 'package:whiteboard_canvas/context_editors/flowchart_editor.dart';

import 'local_store.dart';
import 'theme_service.dart';

/// 应用设置存储（main 创建后经 Provider 下发）。
class WbSettingsStore implements WbThemePrefsSink {
  WbSettingsStore({WbLocalStore? localStore, this.maxRecentBoards = 20})
      : local = localStore ?? WbLocalStore();

  /// 设置文件名。
  static const String fileName = 'settings.json';

  /// 当前设置文件格式版本。
  static const int schemaVersion = 1;

  /// 底座（JSON 文件读写）。
  final WbLocalStore local;

  /// 最近白板列表上限。
  final int maxRecentBoards;

  Map<String, dynamic>? _cache;

  /// 设置文件完整路径（诊断 / 测试用）。
  String get settingsPath => local.pathFor(fileName);

  // ---------------------------------------------------------------------------
  // 主题 / 外观（WbThemePrefsSink 实现）
  // ---------------------------------------------------------------------------

  /// 最近保存的主题 id（空串 = 未保存过）。
  @override
  String get themeId {
    final Object? value = _data()['themeId'];
    return value is String ? value : '';
  }

  @override
  set themeId(String value) => _write('themeId', value);

  /// 最近保存的外观偏好（缺失 / 损坏时返回默认）。
  @override
  WbAppearancePrefs get appearance {
    final Object? raw = _data()['appearance'];
    if (raw is Map) {
      return WbAppearancePrefs.fromJson(Map<String, dynamic>.from(raw));
    }
    return const WbAppearancePrefs();
  }

  @override
  set appearance(WbAppearancePrefs value) =>
      _write('appearance', value.toJson());

  // ---------------------------------------------------------------------------
  // 流程图图形库偏好
  // ---------------------------------------------------------------------------

  /// 流程图编辑器图形库偏好（`flowLibrary` 键：启用 / 折叠的库与
  /// 「我的组件」；null = 从未保存过）。
  WbFlowLibraryPrefs? get flowLibrary {
    final Object? raw = _data()['flowLibrary'];
    if (raw is! Map) {
      return null;
    }
    return WbFlowLibraryPrefs.fromJson(
      raw,
      defaultEnabled: flowLibraryDefaultEnabled,
    );
  }

  set flowLibrary(WbFlowLibraryPrefs? value) {
    if (value == null) {
      _data().remove('flowLibrary');
      _flush();
      return;
    }
    _write('flowLibrary', value.toJson());
  }

  /// 全部图形库 id（`enabledLibraries` 字段缺失时的默认启用集合）。
  static final Set<String> flowLibraryDefaultEnabled = <String>{
    for (final WbFlowShapeLibrary library in WbFlowShapeLibrary.values)
      library.id,
  };

  // ---------------------------------------------------------------------------
  // AI 提供商配置
  // ---------------------------------------------------------------------------

  /// AI 提供商配置（null = 从未配置过，启动时不注入 provider）。
  WbAiSettings? get ai {
    final Object? raw = _data()['ai'];
    if (raw is Map) {
      return WbAiSettings.fromJson(Map<String, dynamic>.from(raw));
    }
    return null;
  }

  set ai(WbAiSettings? value) {
    if (value == null) {
      _data().remove('ai');
      _flush();
      return;
    }
    _write('ai', value.toJson());
  }

  // ---------------------------------------------------------------------------
  // 协作服务地址
  // ---------------------------------------------------------------------------

  /// 协作服务端地址（空串 = 未配置）。
  String get syncServerUrl {
    final Object? raw = _data()['sync'];
    if (raw is Map && raw['serverUrl'] is String) {
      return raw['serverUrl'] as String;
    }
    return '';
  }

  set syncServerUrl(String value) {
    final Map<String, dynamic> data = _data();
    final Object? raw = data['sync'];
    final Map<String, dynamic> merged = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    merged['serverUrl'] = value;
    data['sync'] = merged;
    _flush();
  }

  // ---------------------------------------------------------------------------
  // 最近打开的白板
  // ---------------------------------------------------------------------------

  /// 最近打开的白板（最新在前；坏条目静默跳过）。
  List<WbRecentBoardEntry> get recentBoards {
    final Object? raw = _data()['recentBoards'];
    if (raw is! List) {
      return const <WbRecentBoardEntry>[];
    }
    final List<WbRecentBoardEntry> entries = <WbRecentBoardEntry>[];
    for (final Object? item in raw) {
      if (item is Map) {
        final WbRecentBoardEntry entry =
            WbRecentBoardEntry.fromJson(Map<String, dynamic>.from(item));
        if (entry.path.isNotEmpty) {
          entries.add(entry);
        }
      }
    }
    return List<WbRecentBoardEntry>.unmodifiable(entries);
  }

  /// 记录一条最近打开记录（按路径去重、最新在前、截断到上限）。
  void rememberBoard({required String path, String name = ''}) {
    if (path.isEmpty) {
      return;
    }
    final List<WbRecentBoardEntry> merged = <WbRecentBoardEntry>[
      WbRecentBoardEntry(
        path: path,
        name: name,
        updatedAt: DateTime.now().toIso8601String(),
      ),
    ];
    for (final WbRecentBoardEntry entry in recentBoards) {
      if (entry.path != path && merged.length < maxRecentBoards) {
        merged.add(entry);
      }
    }
    _data()['recentBoards'] = merged
        .map((WbRecentBoardEntry entry) => entry.toJson())
        .toList(growable: false);
    _flush();
  }

  /// 从最近列表移除一条记录（失效路径清理用）。
  void removeRecentBoard(String path) {
    final List<WbRecentBoardEntry> current = recentBoards
        .where((WbRecentBoardEntry entry) => entry.path != path)
        .toList(growable: false);
    if (current.length == recentBoards.length) {
      return;
    }
    _data()['recentBoards'] = current
        .map((WbRecentBoardEntry entry) => entry.toJson())
        .toList(growable: false);
    _flush();
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  /// 惰性加载并缓存设置对象（缺失 / 坏文件 → 空对象）。
  Map<String, dynamic> _data() =>
      _cache ??= local.readJson(fileName) ?? <String, dynamic>{};

  void _write(String key, Object? value) {
    _data()[key] = value;
    _flush();
  }

  /// 落盘（自动补版本号；IO 失败静默返回 false，内存态仍完整）。
  bool _flush() {
    final Map<String, dynamic> data = _data();
    data['version'] = schemaVersion;
    return local.writeJson(fileName, data);
  }
}

/// AI 提供商配置（设置页「应用」后持久化；启动恢复共用 [build]）。
class WbAiSettings {
  const WbAiSettings({
    this.kind = kindOpenAi,
    this.apiKey = '',
    this.model = '',
    this.baseUrl = '',
  });

  /// 提供商类型：OpenAI。
  static const String kindOpenAi = 'openai';

  /// 提供商类型：Anthropic。
  static const String kindAnthropic = 'anthropic';

  /// 提供商类型：自定义 / 自托管（OpenAI 兼容）。
  static const String kindCustom = 'custom';

  /// 自定义端点默认基地址（与设置页默认值一致）。
  static const String defaultCustomBaseUrl = 'http://localhost:8080/v1';

  /// [kindOpenAi] / [kindAnthropic] / [kindCustom] 之一。
  final String kind;

  /// API 密钥（明文落盘，用户已确认接受）。
  final String apiKey;

  /// 模型名（空串 = 按 [build] 回退类型默认）。
  final String model;

  /// 自定义端点基地址（仅 [kindCustom] 使用）。
  final String baseUrl;

  /// 构建 Provider（模型缺省回退类型默认，与设置页语义一致）。
  AiProvider build() {
    switch (kind) {
      case kindAnthropic:
        return AnthropicProvider(
          apiKey: apiKey,
          model: model.isEmpty ? 'claude-3-5-sonnet-latest' : model,
        );
      case kindCustom:
        return CustomProvider(
          baseUrl: baseUrl.isEmpty ? defaultCustomBaseUrl : baseUrl,
          apiKey: apiKey,
          model: model.isEmpty ? 'internal-large' : model,
        );
      default:
        return OpenAiProvider(
          apiKey: apiKey,
          model: model.isEmpty ? 'gpt-4o-mini' : model,
        );
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'apiKey': apiKey,
        'model': model,
        'baseUrl': baseUrl,
      };

  factory WbAiSettings.fromJson(Map<String, dynamic> json) {
    String read(String key) => json[key] is String ? json[key] as String : '';
    final String kind = read('kind');
    return WbAiSettings(
      kind: kind.isEmpty ? kindOpenAi : kind,
      apiKey: read('apiKey'),
      model: read('model'),
      baseUrl: read('baseUrl'),
    );
  }
}

/// 最近打开的白板条目。
class WbRecentBoardEntry {
  const WbRecentBoardEntry({
    required this.path,
    this.name = '',
    this.updatedAt = '',
  });

  /// 文件绝对路径。
  final String path;

  /// 白板名（空串 = 用文件名兜底展示）。
  final String name;

  /// 最近一次打开 / 保存时间（ISO8601，空串 = 未知）。
  final String updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'name': name,
        'updatedAt': updatedAt,
      };

  factory WbRecentBoardEntry.fromJson(Map<String, dynamic> json) {
    String read(String key) => json[key] is String ? json[key] as String : '';
    return WbRecentBoardEntry(
      path: read('path'),
      name: read('name'),
      updatedAt: read('updatedAt'),
    );
  }
}
