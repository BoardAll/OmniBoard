/// Markdown 元素模型（payload）：Markdown source 是唯一真实数据。
///
/// 参照《OmniBoard Markdown 渲染与交互实现方案》§3 / §25：
/// AST、Layout、Render Scene 均为可重建派生数据，不进入 payload；
/// 同步 / 持久化只携带 `type / id / bounds / data.source`。
library;

/// Markdown 元素 payload（存于 `WbCanvasElement.payload`）。
class WbMarkdownModel {
  /// 创建模型。
  const WbMarkdownModel({this.source = defaultSource, this.autoHeight = false});

  /// 工具栏创建时的默认内容（方案 §17）。
  static const String defaultSource = '# Markdown\n\n开始编辑...';

  /// Markdown 源文本（唯一真实数据）。
  final String source;

  /// 自适应高度（宿主可按内容测量回写元素高度）。
  final bool autoHeight;

  /// 默认模型（快速创建 / 未编辑确认时使用）。
  static WbMarkdownModel sample() => const WbMarkdownModel();

  /// 从任意 payload 形态归一为模型：已是模型原样返回；
  /// `{source, options:{autoHeight}}` 形态的 Map（.wbd 解码 / 引擎
  /// 往返 / AI 工具批量插入）转模型；其余返回 null。
  static WbMarkdownModel? fromPayload(Object? payload) {
    if (payload is WbMarkdownModel) {
      return payload;
    }
    if (payload is Map) {
      return WbMarkdownModel.fromJson(Map<String, dynamic>.from(payload));
    }
    return null;
  }

  /// 复制并覆盖字段。
  WbMarkdownModel copyWith({String? source, bool? autoHeight}) {
    return WbMarkdownModel(
      source: source ?? this.source,
      autoHeight: autoHeight ?? this.autoHeight,
    );
  }

  /// 序列化（.wbd / 协同同步 payload）。
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'source': source,
      'options': <String, dynamic>{'autoHeight': autoHeight},
    };
  }

  /// 反序列化（字段缺失 / 类型不符时取默认值，容忍坏数据）。
  factory WbMarkdownModel.fromJson(Map<String, dynamic> json) {
    final Object? source = json['source'];
    final Object? options = json['options'];
    bool autoHeight = false;
    if (options is Map && options['autoHeight'] is bool) {
      autoHeight = options['autoHeight'] as bool;
    }
    return WbMarkdownModel(
      source: source is String ? source : '',
      autoHeight: autoHeight,
    );
  }

  @override
  String toString() => 'WbMarkdownModel(${source.length} chars)';
}
