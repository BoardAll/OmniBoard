/// 画布本地存储抽象（浏览器 localStorage 语义的字符串键值读写）。
///
/// Web 端持久化链路：`WbPersistentCanvasStore` 在画布事务提交点把全量
/// 页元素快照（按页合并的 `.wbd` JSON 编码）写穿到本接口；页面重新
/// 加载、引擎侧为空时从存档恢复并回灌引擎。
///
/// 实现经条件导入选择（见 `wb_browser_io.dart`）：Web 编译为浏览器
/// localStorage，非 Web 编译（VM 测试 / 其他宿主）为进程内 Map。
/// 约定：读失败返回 null、写失败静默，任何实现都不抛异常。
library;

/// 画布本地存储（字符串键值）。
abstract interface class WbCanvasStorage {
  /// 读取键值（不存在 / 读取失败返回 null）。
  String? read(String key);

  /// 写入键值（失败静默，例如配额超限 / 存储被禁用）。
  void write(String key, String value);

  /// 删除键值（失败静默）。
  void clear(String key);
}
