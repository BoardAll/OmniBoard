/// 元素 API（Open API §5.3）。
library;

import 'api_client.dart';

class WbElementsApi {
  const WbElementsApi(this._client);

  final WbApiClient _client;

  /// `GET /pages/{pageId}/elements` — 列出元素（分页）。
  Future<WbPageResult<WbApiElement>> list(
    String pageId, {
    WbListQuery query = const WbListQuery(),
  }) {
    return _client.requestPaged<WbApiElement>(
      'GET',
      '/pages/$pageId/elements',
      query: query.toQuery(),
      fromJson: WbApiElement.fromJson,
    );
  }

  /// `POST /pages/{pageId}/elements` — 批量创建元素。
  ///
  /// [elements] 为原始 JSON 元素列表（类型专属字段由服务端校验）；
  /// [dryRun] 为 true 时仅校验不落库。
  Future<List<WbApiElement>> create(
    String pageId, {
    required List<Map<String, dynamic>> elements,
    bool dryRun = false,
    String? idempotencyKey,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/pages/$pageId/elements',
      body: <String, dynamic>{
        'elements': elements,
        'dryRun': dryRun,
      },
      idempotencyKey: idempotencyKey,
    );
    final Object? created = data['elements'];
    if (created is List) {
      return created
          .whereType<Map<dynamic, dynamic>>()
          .map((Map<dynamic, dynamic> m) =>
              WbApiElement.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);
    }
    return data.isEmpty
        ? const <WbApiElement>[]
        : <WbApiElement>[WbApiElement.fromJson(data)];
  }

  /// `GET /elements/{elementId}` — 获取元素。
  Future<WbApiElement> get(String elementId) async {
    final Map<String, dynamic> data =
        await _client.requestObject('GET', '/elements/$elementId');
    return WbApiElement.fromJson(data);
  }

  /// `PATCH /elements/{elementId}` — 更新元素（原样透传 patch）。
  Future<WbApiElement> update(
    String elementId,
    Map<String, dynamic> patch,
  ) async {
    final Map<String, dynamic> data =
        await _client.requestObject('PATCH', '/elements/$elementId', body: patch);
    return WbApiElement.fromJson(data);
  }

  /// `DELETE /elements/{elementId}` — 删除元素。
  Future<void> delete(String elementId) async {
    await _client.send('DELETE', '/elements/$elementId');
  }

  /// `POST /elements/batch` — 批量操作（create / update / delete / move）。
  Future<List<WbApiElement>> batch(
    List<WbApiElementOp> ops, {
    bool dryRun = false,
    String? idempotencyKey,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/elements/batch',
      body: <String, dynamic>{
        'ops': ops.map((WbApiElementOp op) => op.toJson()).toList(),
        'dryRun': dryRun,
      },
      idempotencyKey: idempotencyKey,
    );
    final Object? elements = data['elements'];
    if (elements is List) {
      return elements
          .whereType<Map<dynamic, dynamic>>()
          .map((Map<dynamic, dynamic> m) =>
              WbApiElement.fromJson(Map<String, dynamic>.from(m)))
          .toList(growable: false);
    }
    return const <WbApiElement>[];
  }

  /// `POST /elements/{elementId}/style` — 设置样式（合并进现有 style）。
  Future<WbApiElement> setStyle(
    String elementId,
    Map<String, dynamic> style,
  ) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/elements/$elementId/style',
      body: <String, dynamic>{'style': style},
    );
    return WbApiElement.fromJson(data);
  }

  /// `POST /elements/{elementId}/move` — 移动元素。
  ///
  /// [relative] 为 true 时 [x]/[y] 视为增量（dx/dy）。
  Future<WbApiElement> move(
    String elementId, {
    required double x,
    required double y,
    bool relative = false,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/elements/$elementId/move',
      body: <String, dynamic>{
        'x': x,
        'y': y,
        if (relative) 'relative': true,
      },
    );
    return WbApiElement.fromJson(data);
  }

  /// `POST /elements/{elementId}/resize` — 缩放元素。
  Future<WbApiElement> resize(
    String elementId, {
    required double width,
    required double height,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/elements/$elementId/resize',
      body: <String, dynamic>{'width': width, 'height': height},
    );
    return WbApiElement.fromJson(data);
  }

  /// `POST /elements/align` — 对齐。
  ///
  /// [align]：left / center-h / right / top / center-v / bottom。
  Future<void> align({
    required List<String> elementIds,
    required String align,
  }) async {
    await _client.send(
      'POST',
      '/elements/align',
      body: <String, dynamic>{'elementIds': elementIds, 'align': align},
    );
  }

  /// `POST /elements/distribute` — 分布。
  ///
  /// [axis]：horizontal / vertical。
  Future<void> distribute({
    required List<String> elementIds,
    String axis = 'horizontal',
  }) async {
    await _client.send(
      'POST',
      '/elements/distribute',
      body: <String, dynamic>{'elementIds': elementIds, 'axis': axis},
    );
  }

  /// `POST /elements/group` — 分组，返回新分组 id。
  Future<String> group(List<String> elementIds) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/elements/group',
      body: <String, dynamic>{'elementIds': elementIds},
    );
    if (data['groupId'] is String) {
      return data['groupId'] as String;
    }
    final Object? group = data['group'];
    if (group is Map && group['id'] is String) {
      return group['id'] as String;
    }
    return '';
  }

  /// `POST /elements/ungroup` — 取消分组，返回被释放的元素 id。
  Future<List<String>> ungroup({
    String? groupId,
    List<String>? elementIds,
  }) async {
    final Map<String, dynamic> data = await _client.requestObject(
      'POST',
      '/elements/ungroup',
      body: <String, dynamic>{
        if (groupId != null) 'groupId': groupId,
        if (elementIds != null && elementIds.isNotEmpty) 'elementIds': elementIds,
      },
    );
    final Object? released = data['elementIds'];
    if (released is List) {
      return released.whereType<String>().toList(growable: false);
    }
    return const <String>[];
  }
}
