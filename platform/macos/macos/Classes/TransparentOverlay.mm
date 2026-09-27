//
// TransparentOverlay.mm
// 透明批注覆盖面板实现（Objective-C++ / Cocoa）。
//
// 面板特性：
//   - 无边框 + 非激活（NSWindowStyleMaskBorderless |
//     NSWindowStyleMaskNonactivatingPanel），不抢下层应用焦点；
//   - 背景全透明（isOpaque=NO + clearColor + 无阴影）；
//   - 跨空间：CanJoinAllSpaces | FullScreenAuxiliary | Stationary，
//     全屏应用之上仍可见且不随空间切换移动；
//   - 默认穿透态，批注态通过 setClickThrough:NO 恢复鼠标接收。
// 所有方法必须在主线程调用。
//

#import "TransparentOverlay.h"

#pragma mark - 私有接口

@interface WbTransparentOverlay ()
+ (instancetype)overlayWithFrame:(NSRect)frame screen:(nullable NSScreen*)screen;
- (void)configureOverlay;
@end

#pragma mark - 实现

@implementation WbTransparentOverlay

+ (instancetype)overlayForMainScreen {
  NSScreen* screen = [NSScreen mainScreen];
  if (screen == nil) {
    return nil;
  }
  return [self overlayWithFrame:screen.frame screen:screen];
}

+ (instancetype)overlayForAllScreens {
  NSArray<NSScreen*>* screens = [NSScreen screens];
  if (screens.count == 0) {
    return nil;
  }
  NSRect unionFrame = NSZeroRect;
  for (NSScreen* screen in screens) {
    unionFrame = NSUnionRect(unionFrame, screen.frame);
  }
  return [self overlayWithFrame:unionFrame screen:screens.firstObject];
}

+ (instancetype)overlayWithFrame:(NSRect)frame screen:(NSScreen*)screen {
  WbTransparentOverlay* overlay =
      [[WbTransparentOverlay alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskBorderless |
                                                        NSWindowStyleMaskNonactivatingPanel
                                                backing:NSBackingStoreBuffered
                                                  defer:NO
                                                 screen:screen];
  if (overlay == nil) {
    return nil;
  }
  [overlay configureOverlay];
  return overlay;
}

- (void)configureOverlay {
  self.opaque = NO;
  self.backgroundColor = [NSColor clearColor];
  self.hasShadow = NO;
  // 与《透明批注模式技术方案》§7.2 的置顶层级一致，确保覆盖全屏应用。
  self.level = NSScreenSaverWindowLevel;
  self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                            NSWindowCollectionBehaviorFullScreenAuxiliary |
                            NSWindowCollectionBehaviorStationary;
  // 默认穿透态（进入覆盖层先不拦截桌面操作）。
  self.ignoresMouseEvents = YES;
  self.acceptsMouseMovedEvents = NO;
  self.releasedWhenClosed = NO;
  self.becomesKeyOnlyIfNeeded = YES;
  self.animationBehavior = NSWindowAnimationBehaviorNone;
}

- (void)fitToScreen:(NSScreen*)screen {
  if (screen == nil) {
    return;
  }
  [self setFrame:screen.frame display:YES];
}

- (void)setOverlayVisible:(BOOL)visible {
  if (visible) {
    // orderFrontRegardless：不激活应用、不打断下层操作地把覆盖层置于最前。
    [self orderFrontRegardless];
  } else {
    [self orderOut:nil];
  }
}

- (void)setClickThrough:(BOOL)clickThrough {
  self.ignoresMouseEvents = clickThrough;
  self.acceptsMouseMovedEvents = !clickThrough;
}

#pragma mark - 窗口行为

- (BOOL)canBecomeKeyWindow {
  // 覆盖面板不成为 key window，避免夺走下层应用的键盘焦点；
  // 批注工具条等若需要键盘输入，由上层用独立小窗口承载。
  return NO;
}

- (BOOL)canBecomeMainWindow {
  return NO;
}

@end
