/// WASM 核心加载的公共类型（Web 与桩实现共用）。
library;

/// WASM 核心（`wb_core.wasm`）的加载状态。
///
/// 状态机：idle → loading → ready / unavailable。
/// [unavailable] 表示"非 Web 环境或资源缺失"，加载失败不抛异常
/// （《Web 端方案设计（Flutter Web + WASM）v1.0》§6、§9.4）。
enum WbCoreStatus {
  /// 尚未开始加载（初始状态）。
  idle('idle', '未加载'),

  /// 加载中（脚本注入 / WASM 实例化）。
  loading('loading', '加载中'),

  /// 加载成功，[WbCoreLoader.call] 等代理可用。
  ready('ready', '已就绪'),

  /// 不可用：非 Web 环境、`wb_core.js` 缺失或加载失败。
  unavailable('unavailable', '不可用');

  const WbCoreStatus(this.id, this.label);

  /// 稳定 id（日志 / 持久化用）。
  final String id;

  /// 中文显示名（UI 提示用）。
  final String label;

  /// 是否可用（仅 [ready] 为 true）。
  bool get isAvailable => this == WbCoreStatus.ready;
}

/// `cwrap` 代理函数：把 Dart 参数列表转成对应 C 符号调用。
///
/// 参数仅支持 `null` / `String` / `int` / `double` / `bool`；
/// 返回值为转换后的 Dart 值（数字 / 字符串 / 布尔 / 不透明 JS 对象 / null）。
typedef WbCoreCallable = Object? Function(List<Object?> args);
