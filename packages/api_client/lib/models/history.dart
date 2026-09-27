/// 历史与撤销模型（Open API §5.7）。
class WbApiHistory {
  const WbApiHistory({
    this.entries = const <WbApiHistoryEntry>[],
    this.canUndo = false,
    this.canRedo = false,
    this.undoCount = 0,
    this.redoCount = 0,
    this.raw = const <String, dynamic>{},
  });

  final List<WbApiHistoryEntry> entries;
  final bool canUndo;
  final bool canRedo;

  /// 可撤销步数。
  final int undoCount;

  /// 可重做步数。
  final int redoCount;

  final Map<String, dynamic> raw;

  factory WbApiHistory.fromJson(Map<String, dynamic> json) {
    final Object? entries = json['entries'];
    final List<WbApiHistoryEntry> parsed = entries is List
        ? entries
            .whereType<Map<dynamic, dynamic>>()
            .map((Map<dynamic, dynamic> m) =>
                WbApiHistoryEntry.fromJson(Map<String, dynamic>.from(m)))
            .toList(growable: false)
        : const <WbApiHistoryEntry>[];
    final int undoCount = json['undoCount'] is num
        ? (json['undoCount'] as num).toInt()
        : parsed.length;
    return WbApiHistory(
      entries: parsed,
      canUndo: json['canUndo'] is bool
          ? json['canUndo'] as bool
          : undoCount > 0,
      canRedo: json['canRedo'] is bool
          ? json['canRedo'] as bool
          : (json['redoCount'] is num && (json['redoCount'] as num) > 0),
      undoCount: undoCount,
      redoCount: json['redoCount'] is num
          ? (json['redoCount'] as num).toInt()
          : 0,
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'entries':
              entries.map((WbApiHistoryEntry e) => e.toJson()).toList(),
          'canUndo': canUndo,
          'canRedo': canRedo,
          'undoCount': undoCount,
          'redoCount': redoCount,
        };

  @override
  String toString() =>
      'WbApiHistory(${entries.length} entries, undo=$canUndo, redo=$canRedo)';
}

/// 历史记录条目。
class WbApiHistoryEntry {
  const WbApiHistoryEntry({
    required this.id,
    this.op = '',
    this.description = '',
    this.userId = '',
    this.pageId = '',
    this.timestamp = '',
    this.raw = const <String, dynamic>{},
  });

  final String id;

  /// 操作类型（如 element.create / page.move）。
  final String op;

  /// 人类可读描述。
  final String description;
  final String userId;
  final String pageId;

  /// ISO 8601 UTC。
  final String timestamp;

  final Map<String, dynamic> raw;

  factory WbApiHistoryEntry.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    return WbApiHistoryEntry(
      id: readStr('id'),
      op: readStr('op'),
      description: json['description'] is String
          ? json['description'] as String
          : readStr('label'),
      userId: json['userId'] is String
          ? json['userId'] as String
          : readStr('createdBy'),
      pageId: readStr('pageId'),
      timestamp: readStr('timestamp'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'op': op,
          'description': description,
          'userId': userId,
          'pageId': pageId,
          'timestamp': timestamp,
        };

  @override
  String toString() => 'WbApiHistoryEntry($id, $op)';
}

/// 撤销 / 重做结果（`POST /boards/{boardId}/undo|redo`）。
class WbApiUndoResult {
  const WbApiUndoResult({
    this.applied = false,
    this.history = const WbApiHistory(),
    this.affected = const <String>[],
    this.raw = const <String, dynamic>{},
  });

  /// 是否实际执行了撤销 / 重做（栈空时为 false）。
  final bool applied;

  /// 操作后的历史状态。
  final WbApiHistory history;

  /// 受影响的元素 id 列表。
  final List<String> affected;

  final Map<String, dynamic> raw;

  factory WbApiUndoResult.fromJson(Map<String, dynamic> json) {
    final Object? affected = json['affected'];
    return WbApiUndoResult(
      applied: json['applied'] is bool
          ? json['applied'] as bool
          : json['ok'] is bool
              ? json['ok'] as bool
              : true,
      history: json['history'] is Map
          ? WbApiHistory.fromJson(
              Map<String, dynamic>.from(json['history'] as Map))
          : WbApiHistory.fromJson(json),
      affected: affected is List
          ? affected.whereType<String>().toList(growable: false)
          : const <String>[],
      raw: json,
    );
  }
}
