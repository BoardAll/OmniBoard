/// 统一窗口接口与 Web 窗口能力模型。
library;

/// 统一窗口插件接口（《Flutter + C++ 工程结构设计》§6.5）。
///
/// Windows / macOS / Web 提供同名接口与语义；调用方（应用层）按平台
/// 选择实现。Web 端仅全屏可用，其余能力为 no-op（浏览器安全模型限制，
/// 见 [WebWindowCapabilities]）；非 Web 环境（`flutter test` / 桌面宿主）
/// 全部能力不可用，调用静默完成，均不抛异常。
abstract class WbWindowPlugin {
  /// 窗口背景是否透明（Web 端不支持）。
  Future<void> setTransparent(bool transparent);

  /// 是否始终置顶（Web 端不支持）。
  Future<void> setAlwaysOnTop(bool onTop);

  /// 是否忽略鼠标事件 / 点击穿透（Web 端不支持）。
  ///
  /// [forward] 为 true 时仍接收鼠标移动消息（Windows 语义；Web 端忽略）。
  Future<void> setIgnoreMouseEvents(bool ignore, {bool forward = false});

  /// 全屏切换（Web 端映射到 Fullscreen API）。
  Future<void> setFullscreen(bool fullscreen);

  /// 移动窗口到屏幕坐标（Web 端不支持）。
  Future<void> setPosition(int x, int y);

  /// 调整窗口尺寸（Web 端不支持）。
  Future<void> setSize(int width, int height);
}

/// Web 端窗口能力查询结果（`isSupported` 语义）。
///
/// 浏览器差异说明：
/// - **全屏**：所有主流浏览器支持 `Element.requestFullscreen()`
///   （Chrome 90+ / Edge 90+ / Safari 15+ / Firefox 90+），但必须由
///   用户手势触发，否则 Promise 被拒绝；
/// - **透明 / 置顶 / 鼠标穿透 / 位置 / 尺寸**：均不支持。浏览器不允许
///   页面控制系统级窗口装饰与层级：`pointer-events` 只能影响页面内元素，
///   不能把鼠标事件交给下层应用；"透明批注""鼠标穿透"在 Web 端按设计
///   隐藏入口（《Web 端方案设计》§2.1、§16.1）。
class WebWindowCapabilities {
  /// 创建能力描述。
  const WebWindowCapabilities({
    required this.fullscreen,
    this.transparent = false,
    this.alwaysOnTop = false,
    this.ignoreMouseEvents = false,
    this.position = false,
    this.size = false,
  });

  /// 浏览器能力集：仅全屏可用。
  static const WebWindowCapabilities browser =
      WebWindowCapabilities(fullscreen: true);

  /// 非 Web 环境：全部能力不可用。
  static const WebWindowCapabilities none =
      WebWindowCapabilities(fullscreen: false);

  /// 全屏是否可用。
  final bool fullscreen;

  /// 窗口透明是否可用。
  final bool transparent;

  /// 窗口置顶是否可用。
  final bool alwaysOnTop;

  /// 鼠标穿透是否可用。
  final bool ignoreMouseEvents;

  /// 窗口定位是否可用。
  final bool position;

  /// 窗口尺寸调整是否可用。
  final bool size;
}
