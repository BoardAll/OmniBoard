/// AI 上下文模型（《AI 助手与 MCP 设计》§4.4 上下文控制）。
library;

/// 上下文范围。
abstract final class AiContextScope {
  static const String selection = 'selection';
  static const String frame = 'frame';
  static const String page = 'page';
  static const String board = 'board';
  static const String custom = 'custom';
}

/// AI 可操作的上下文范围与读取授权。
class AiContext {
  const AiContext({
    this.boardId = '',
    this.pageId = '',
    this.frameId = '',
    this.selection = const <String>[],
    this.scope = AiContextScope.page,
    this.allowComments = false,
    this.allowImageOcr = false,
    this.extra = const <String, dynamic>{},
  });

  final String boardId;
  final String pageId;
  final String frameId;

  /// 选区元素 id 列表。
  final List<String> selection;

  /// selection / frame / page / board / custom。
  final String scope;

  /// 是否允许 AI 读取评论。
  final bool allowComments;

  /// 是否允许 AI 读取图片 OCR。
  final bool allowImageOcr;

  /// 附加上下文（如视口、筛选条件）。
  final Map<String, dynamic> extra;

  bool get isEmpty =>
      boardId.isEmpty && pageId.isEmpty && selection.isEmpty && frameId.isEmpty;

  /// 供 AI 面板顶部展示的一句话摘要。
  String get summary {
    switch (scope) {
      case AiContextScope.selection:
        return selection.isEmpty ? '未选择对象' : '选中 ${selection.length} 个对象';
      case AiContextScope.frame:
        return frameId.isEmpty ? '当前 Frame' : 'Frame $frameId';
      case AiContextScope.board:
        return '整个白板';
      case AiContextScope.custom:
        return '自定义范围';
      default:
        return '当前页面';
    }
  }

  /// 用 [override] 中非空字段覆盖当前上下文（面板上修改上下文时使用）。
  AiContext merge(AiContext override) {
    return AiContext(
      boardId: override.boardId.isNotEmpty ? override.boardId : boardId,
      pageId: override.pageId.isNotEmpty ? override.pageId : pageId,
      frameId: override.frameId.isNotEmpty ? override.frameId : frameId,
      selection:
          override.selection.isNotEmpty ? override.selection : selection,
      scope: override.scope.isNotEmpty ? override.scope : scope,
      allowComments: allowComments || override.allowComments,
      allowImageOcr: allowImageOcr || override.allowImageOcr,
      extra: <String, dynamic>{...extra, ...override.extra},
    );
  }

  AiContext copyWith({
    String? boardId,
    String? pageId,
    String? frameId,
    List<String>? selection,
    String? scope,
    bool? allowComments,
    bool? allowImageOcr,
    Map<String, dynamic>? extra,
  }) {
    return AiContext(
      boardId: boardId ?? this.boardId,
      pageId: pageId ?? this.pageId,
      frameId: frameId ?? this.frameId,
      selection: selection ?? this.selection,
      scope: scope ?? this.scope,
      allowComments: allowComments ?? this.allowComments,
      allowImageOcr: allowImageOcr ?? this.allowImageOcr,
      extra: extra ?? this.extra,
    );
  }

  factory AiContext.fromJson(Map<String, dynamic> json) {
    String readStr(String key) =>
        json[key] is String ? json[key] as String : '';
    final Object? selection = json['selection'];
    return AiContext(
      boardId: readStr('boardId'),
      pageId: readStr('pageId'),
      frameId: readStr('frameId'),
      selection: selection is List
          ? selection.whereType<String>().toList(growable: false)
          : const <String>[],
      scope: readStr('scope').isNotEmpty
          ? readStr('scope')
          : AiContextScope.page,
      allowComments: json['allowComments'] == true,
      allowImageOcr: json['allowImageOcr'] == true,
      extra: json['extra'] is Map
          ? Map<String, dynamic>.from(json['extra'] as Map)
          : const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'boardId': boardId,
        'pageId': pageId,
        if (frameId.isNotEmpty) 'frameId': frameId,
        if (selection.isNotEmpty) 'selection': selection,
        'scope': scope,
        'allowComments': allowComments,
        'allowImageOcr': allowImageOcr,
        if (extra.isNotEmpty) 'extra': extra,
      };

  @override
  String toString() => 'AiContext($scope, $summary)';
}
