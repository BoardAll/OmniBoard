//
// WindowPlugin.mm
// 窗口能力实现（Objective-C++ / Cocoa）。
//
// 所有方法必须在主线程调用（Flutter 方法通道默认主线程分发）；
// window 为 nil 时静默返回，由调用方（WhiteboardMacosPlugin）负责报错。
//

#import "WindowPlugin.h"

@implementation WbWindowPlugin

+ (void)setTransparent:(BOOL)transparent forWindow:(NSWindow*)window {
  if (window == nil) {
    return;
  }
  if (transparent) {
    window.opaque = NO;
    window.backgroundColor = [NSColor clearColor];
    window.hasShadow = NO;
    // 窗口整体 alpha 保持 1.0；“透明感”由 clear 背景 + Flutter 渲染层
    // 共同决定，避免窗口级 alpha 让所有内容一起变淡。
    window.alphaValue = 1.0;
  } else {
    window.opaque = YES;
    window.backgroundColor = [NSColor windowBackgroundColor];
    window.hasShadow = YES;
    window.alphaValue = 1.0;
  }
}

+ (void)setAlwaysOnTop:(BOOL)onTop forWindow:(NSWindow*)window {
  if (window == nil) {
    return;
  }
  // 批注场景需要覆盖全屏应用与（部分）系统 UI；NSScreenSaverWindowLevel
  // 与《透明批注模式技术方案》§7.2 的置顶层级一致。
  window.level = onTop ? NSScreenSaverWindowLevel : NSNormalWindowLevel;
}

+ (void)setIgnoreMouseEvents:(BOOL)ignore
                     forward:(BOOL)forward
                   forWindow:(NSWindow*)window {
  if (window == nil) {
    return;
  }
  window.ignoresMouseEvents = ignore;
  // 批注态恢复移动事件（悬停高亮等）；穿透态下 AppKit 不再向窗口投递
  // 任何鼠标事件。
  window.acceptsMouseMovedEvents = !ignore;
  // forward（悬停高亮）限制说明：
  // Win32 通过 WS_EX_TRANSPARENT + 手动转发 WM_MOUSEMOVE 实现“点击穿透
  // 但保留悬停”；macOS 的 ignoresMouseEvents 是布尔开关，事件要么全部
  // 投递到窗口、要么全部穿透到下层，系统不提供“仅转发 move”的机制。
  // 此处接受 forward 参数仅为保持跨平台契约兼容（契约冻结），
  // 不产生额外行为；上层如需穿透态悬停反馈，可用全局事件监视器
  // （NSEvent addGlobalMonitorForEventsMatchingMask）自行实现。
  (void)forward;
}

+ (void)setFullscreen:(BOOL)fullscreen forWindow:(NSWindow*)window {
  if (window == nil) {
    return;
  }
  BOOL isFullscreen = (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
  if (isFullscreen == fullscreen) {
    return;
  }
  NSWindowStyleMask mask = window.styleMask;
  if (fullscreen) {
    mask |= NSWindowStyleMaskFullScreen;
  } else {
    mask &= ~NSWindowStyleMaskFullScreen;
  }
  // 直接改 styleMask 为同步生效；[window toggleFullScreen:] 为动画 +
  // 独立空间（异步完成），与“一键切换”契约的语义差异较大，故不采用。
  [window setStyleMask:mask];
}

+ (void)setPositionX:(int)x y:(int)y forWindow:(NSWindow*)window {
  if (window == nil) {
    return;
  }
  NSScreen* mainScreen = [NSScreen screens].firstObject;
  if (mainScreen == nil) {
    return;
  }
  NSRect frame = window.frame;
  // 坐标换算：输入为主显示器左上角原点（逻辑点，与 Windows 虚拟桌面
  // 语义对齐；负坐标 = 主屏外显示器）。
  // Cocoa 屏幕坐标：主屏左下角为 (0,0)，Y 轴向上。
  //   cocoaX = x
  //   cocoaY = 主屏高度 - y - 窗口高度（保持窗口左上角对齐输入点）
  CGFloat cocoaX = (CGFloat)x;
  CGFloat cocoaY = NSMaxY(mainScreen.frame) - (CGFloat)y - frame.size.height;
  [window setFrameOrigin:NSMakePoint(cocoaX, cocoaY)];
}

+ (void)setContentSizeWidth:(int)width
                     height:(int)height
                  forWindow:(NSWindow*)window {
  if (window == nil) {
    return;
  }
  if (width <= 0 || height <= 0) {
    return;
  }
  // setContentSize 指内容区域（不含标题栏），与 Dart 契约“窗口尺寸”
  // 的直觉一致（Windows 侧同为内容尺寸语义）。
  [window setContentSize:NSMakeSize((CGFloat)width, (CGFloat)height)];
}

@end
