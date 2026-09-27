/// 分页与列表查询（《OpenAPI 规范》§4.5-4.7）。
library;

/// 列表查询参数：`limit` / `cursor` / `sort` / `filter`。
class WbListQuery {
  const WbListQuery({
    this.limit = 20,
    this.cursor,
    this.sort,
    this.filter,
  });

  /// 每页条数（默认 20，最大 100，超限由服务端截断）。
  final int limit;

  /// 游标（上一页 `meta.nextCursor`）。
  final String? cursor;

  /// 排序，如 `createdAt:desc`（字段：createdAt/updatedAt/name/index）。
  final String? sort;

  /// 过滤，如 `type:sticky,color:#FFE58F`（字段：type/color/pageId/createdBy）。
  final String? filter;

  /// 转为 query 参数（省略空值）。
  Map<String, String> toQuery() => <String, String>{
        'limit': '$limit',
        if (cursor != null && cursor!.isNotEmpty) 'cursor': cursor!,
        if (sort != null && sort!.isNotEmpty) 'sort': sort!,
        if (filter != null && filter!.isNotEmpty) 'filter': filter!,
      };

  WbListQuery copyWith({int? limit, String? cursor, String? sort, String? filter}) {
    return WbListQuery(
      limit: limit ?? this.limit,
      cursor: cursor ?? this.cursor,
      sort: sort ?? this.sort,
      filter: filter ?? this.filter,
    );
  }
}

/// 分页结果：`data` 数组 + `meta.nextCursor/hasMore/total`（宽容读取）。
class WbPageResult<T> {
  const WbPageResult({
    required this.items,
    this.nextCursor = '',
    this.hasMore = false,
    this.total = 0,
    this.requestId = '',
  });

  final List<T> items;
  final String nextCursor;
  final bool hasMore;
  final int total;
  final String requestId;

  bool get isEmpty => items.isEmpty;

  int get length => items.length;
}
