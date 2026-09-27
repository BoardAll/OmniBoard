/// 白板模型（Open API `data` 对象）。
class WbApiBoard {
  const WbApiBoard({
    required this.id,
    this.name = '',
    this.description = '',
    this.ownerId = '',
    this.themeId = '',
    this.backgroundId = '',
    this.createdAt = '',
    this.updatedAt = '',
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final String description;
  final String ownerId;
  final String themeId;
  final String backgroundId;

  /// ISO 8601 UTC。
  final String createdAt;
  final String updatedAt;

  final Map<String, dynamic> raw;

  factory WbApiBoard.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    return WbApiBoard(
      id: readStr('id'),
      name: readStr('name'),
      description: readStr('description'),
      ownerId: readStr('ownerId'),
      themeId: readStr('themeId'),
      backgroundId: readStr('backgroundId'),
      createdAt: readStr('createdAt'),
      updatedAt: readStr('updatedAt'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'id': id,
          'name': name,
          'description': description,
          'ownerId': ownerId,
          'themeId': themeId,
          'backgroundId': backgroundId,
          'createdAt': createdAt,
          'updatedAt': updatedAt,
        };

  @override
  String toString() => 'WbApiBoard($id, $name)';
}

/// 协作者（`GET /boards/{boardId}/collaborators`）。
class WbApiCollaborator {
  const WbApiCollaborator({
    required this.userId,
    this.role = '',
    this.scopes = const <String>[],
    this.displayName = '',
    this.joinedAt = '',
    this.raw = const <String, dynamic>{},
  });

  final String userId;

  /// owner / editor / viewer。
  final String role;

  /// 细粒度 scope（空表示由 role 推导）。
  final List<String> scopes;
  final String displayName;
  final String joinedAt;

  final Map<String, dynamic> raw;

  factory WbApiCollaborator.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    final Object? scopes = json['scopes'];
    return WbApiCollaborator(
      userId: readStr('userId'),
      role: readStr('role'),
      scopes: scopes is List
          ? scopes.whereType<String>().toList(growable: false)
          : const <String>[],
      displayName: readStr('displayName'),
      joinedAt: readStr('joinedAt'),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isNotEmpty
      ? raw
      : <String, dynamic>{
          'userId': userId,
          'role': role,
          if (scopes.isNotEmpty) 'scopes': scopes,
          if (displayName.isNotEmpty) 'displayName': displayName,
          'joinedAt': joinedAt,
        };
}

/// 分享结果（`POST /boards/{boardId}/share`）。
class WbApiShareResult {
  const WbApiShareResult({
    this.url = '',
    this.token = '',
    this.expiresAt = '',
    this.raw = const <String, dynamic>{},
  });

  /// 分享链接。
  final String url;
  final String token;
  final String expiresAt;

  final Map<String, dynamic> raw;

  factory WbApiShareResult.fromJson(Map<String, dynamic> json) {
    String readStr(String key) => json[key] is String ? json[key] as String : '';
    return WbApiShareResult(
      url: json['url'] is String ? json['url'] as String : readStr('shareUrl'),
      token: readStr('token'),
      expiresAt: readStr('expiresAt'),
      raw: json,
    );
  }
}
