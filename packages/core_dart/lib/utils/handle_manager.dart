/// 句柄管理（《工程结构》§9.4）。
///
/// C++ 侧返回的 uint64 句柄由引擎持有；本管理器用于把 Dart 侧包装对象
/// （如 [BoardHandle] 包装的 service 上下文）按整数 key 注册/取回。
class WbHandle {
  const WbHandle(this.id);

  /// 无效句柄。
  static const WbHandle invalid = WbHandle(0);

  final int id;

  bool get isValid => id != 0;

  @override
  bool operator ==(Object other) => other is WbHandle && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'WbHandle($id)';
}

/// Dart 侧对象注册表。
class WbHandleManager {
  /// 共享实例（多数应用只需要一个）。
  static final WbHandleManager instance = WbHandleManager();

  final Map<int, Object> _objects = <int, Object>{};
  int _nextId = 1;

  /// 已注册对象数量。
  int get length => _objects.length;

  /// 注册对象并返回句柄。
  WbHandle register(Object obj) {
    final int id = _nextId++;
    _objects[id] = obj;
    return WbHandle(id);
  }

  /// 取回对象（不存在或类型不符返回 null）。
  T? get<T>(WbHandle handle) {
    final Object? value = _objects[handle.id];
    return value is T ? value : null;
  }

  /// 是否存在该句柄。
  bool contains(WbHandle handle) => _objects.containsKey(handle.id);

  /// 注销句柄（返回是否存在）。
  bool unregister(WbHandle handle) => _objects.remove(handle.id) != null;

  /// 清空全部注册对象。
  void clear() => _objects.clear();
}
