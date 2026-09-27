//
// WindowPlugin.h
// 窗口能力（透明 / 置顶 / 点击穿透 / 全屏 / 位置尺寸）。
//
// 对应 Dart `WbWindowPlugin` / `MacosWindowPlugin`（通道 'window.*'），
// 实现参考《透明批注模式技术方案》§7.2：NSWindow 的
// isOpaque / backgroundColor / level / ignoresMouseEvents 等属性。
//

#import <Cocoa/Cocoa.h>

/// 窗口属性操作集合（无状态，纯类方法）。
@interface WbWindowPlugin : NSObject

/// 背景透明开关。
///
/// 开启：isOpaque=NO + clearColor + 去阴影（透明批注覆盖层模式）；
/// 关闭：还原系统默认外观（windowBackgroundColor + 阴影）。
/// 说明：窗口透明只负责窗口层属性，Flutter 渲染层（视图背景）需由
/// 上层再置为透明才能完全看到桌面。
+ (void)setTransparent:(BOOL)transparent forWindow:(NSWindow*)window;

/// 置顶开关：onTop → NSScreenSaverWindowLevel（与文档 §7.2 一致），
/// 否则回 NSNormalWindowLevel。
+ (void)setAlwaysOnTop:(BOOL)onTop forWindow:(NSWindow*)window;

/// 鼠标穿透开关：ignoresMouseEvents。
///
/// [forward] 保留跨平台契约（Win32 下用于转发 mouseMove），macOS 的
/// 事件投递为“全有或全无”，无法只放行鼠标移动而继续穿透点击，
/// 因此本平台忽略该参数（详见实现注释）。
+ (void)setIgnoreMouseEvents:(BOOL)ignore
                     forward:(BOOL)forward
                   forWindow:(NSWindow*)window;

/// 全屏开关（同步切换 styleMask；如需系统动画可改用 toggleFullScreen）。
+ (void)setFullscreen:(BOOL)fullscreen forWindow:(NSWindow*)window;

/// 移动窗口：输入为“主显示器左上角原点”的逻辑坐标（与 Windows 语义
/// 对齐），内部换算为 Cocoa 左下原点；负坐标允许（主屏外显示器）。
+ (void)setPositionX:(int)x y:(int)y forWindow:(NSWindow*)window;

/// 调整内容尺寸（setContentSize，不含标题栏；逻辑点）。
+ (void)setContentSizeWidth:(int)width
                     height:(int)height
                  forWindow:(NSWindow*)window;

@end
