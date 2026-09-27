/// 导出任务模型（Open API §5.6）。
class WbApiExportJob {
  const WbApiExportJob({
    required this.id,
    this.boardId = '',
    this.pageId = '',
    this.format = '',
    this.status = '',
    this.progress = 0,
    this.fileUrl = '',
    this.error = '',
    this.createdAt = '',
    this.updatedAt = '',
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String boardId;
  final String pageId;

  /// 导出格式：pdf / png / svg / pptx / whiteboard。
  final String format;

  /// 任务状态：pending / processing / done / failed。
  final String status;

  /// 进度 0-100。
  final int progress;

  /// 完成后下载地址（也可用 `GET /exports/{exportId}/download`）。
  final String fileUrl;

  /// 失败原因。
  final String error;

  final String createdAt;
  final String updatedAt;

  final Map<String, dynamic> raw;

  bool get isDone => status == 'done';

  bool get isFailed => status == 'failed';

  factory WbApiExportJob.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    return WbApiExportJob(
      id: readStr('id'),
      boardId: readStr('boardId'),
      pageId: readStr('pageId'),
      format: readStr('format'),
      status: readStr('status'),
      progress:
          json['progress'] is num ? (json['progress'] as num).toInt() : 0,
      fileUrl:
          json['fileUrl'] is String ? json['fileUrl'] as String : readStr('url'),
      error: readStr('error'),
      createdAt: readStr('createdAt'),
      updatedAt: readStr('updatedAt'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          if (boardId.isNotEmpty) 'boardId': boardId,
          if (pageId.isNotEmpty) 'pageId': pageId,
          'format': format,
          'status': status,
          'progress': progress,
          if (fileUrl.isNotEmpty) 'fileUrl': fileUrl,
          'createdAt': createdAt,
          'updatedAt': updatedAt,
        };

  @override
  String toString() => 'WbApiExportJob($id, $format, $status $progress%)';
}

/// 导出请求体（`POST /boards/{boardId}/export` / `POST /pages/{pageId}/export`）。
class WbApiExportRequest {
  const WbApiExportRequest({
    required this.format,
    this.pages = const <String>[],
    this.includeAnnotations = true,
    this.quality = '',
  });

  /// pdf / png / svg / pptx / whiteboard。
  final String format;

  /// 指定页面（空表示全部）。
  final List<String> pages;

  final bool includeAnnotations;

  /// low / medium / high。
  final String quality;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'format': format,
        if (pages.isNotEmpty) 'pages': pages,
        'includeAnnotations': includeAnnotations,
        if (quality.isNotEmpty) 'quality': quality,
      };
}
