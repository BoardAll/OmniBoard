//
// TransparentOverlay.h
// 透明批注覆盖面板（无边框 / 跨空间 / 批注-穿透双态）。
//
// 参考《透明批注模式技术方案》§7.2：无边框透明 NSPanel，
// collectionBehavior = CanJoinAllSpaces | FullScreenAuxiliary | Stationary，
// 高窗口层级（NSScreenSaverWindowLevel），全屏贴合指定屏幕。
// 说明：本类为可复用覆盖层骨架，通道接入（overlay.*）走后续 Wave 的
// 契约评审；当前主窗口上的透明 / 穿透由 'window.*' 通道实现。
//

#import <Cocoa/Cocoa.h>

/// 透明批注覆盖面板。
@interface WbTransparentOverlay : NSPanel

/// 创建并配置覆盖主屏幕的面板（未显示，调用方按需
/// [setOverlayVisible:YES]）。无显示器时返回 nil。
+ (nullable instancetype)overlayForMainScreen;

/// 创建覆盖所有屏幕联合区域的面板（多显示器场景）。
+ (nullable instancetype)overlayForAllScreens;

/// 全屏贴合到指定屏幕（frame 对齐 screen.frame）。
- (void)fitToScreen:(nullable NSScreen*)screen;

/// 显示 / 隐藏（orderFrontRegardless，不激活应用）。
- (void)setOverlayVisible:(BOOL)visible;

/// 批注态（NO，接收鼠标）/ 穿透态（YES，忽略鼠标事件）。
- (void)setClickThrough:(BOOL)clickThrough;

@end
