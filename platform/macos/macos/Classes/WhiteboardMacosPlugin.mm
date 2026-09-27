//
// WhiteboardMacosPlugin.mm
// macOS 平台插件入口实现。
//
// 职责：
//   1. 注册 FlutterMethodChannel 'whiteboard/macos'（通道契约冻结）；
//   2. 分发 window.* / shortcut.* / tray.* / capture.* 方法到
//      WindowPlugin / ShortcutPlugin / TrayPlugin / ScreenCapture；
//   3. 持有子模块（热键 / 托盘 / 捕获），在释放时清理原生资源。
// 线程：Flutter 方法通道在平台（主）线程分发，所有子模块均按主线程假设编写。
//

#import "WhiteboardMacosPlugin.h"

#import "ScreenCapture.h"
#import "ShortcutPlugin.h"
#import "TrayPlugin.h"
#import "WindowPlugin.h"

#pragma mark - 私有接口

@interface WhiteboardMacosPlugin ()
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar
                          channel:(FlutterMethodChannel*)channel;
- (nullable NSWindow*)flutterWindow;
- (nullable NSWindow*)requireWindowForResult:(FlutterResult)result;
- (void)handleWindowMethod:(NSString*)method
                 arguments:(NSDictionary*)arguments
                    result:(FlutterResult)result;
- (void)handleShortcutMethod:(NSString*)method
                   arguments:(NSDictionary*)arguments
                      result:(FlutterResult)result;
- (void)handleTrayMethod:(NSString*)method
               arguments:(NSDictionary*)arguments
                  result:(FlutterResult)result;
- (void)handleCaptureMethod:(NSString*)method
                  arguments:(NSDictionary*)arguments
                     result:(FlutterResult)result;
- (BOOL)boolFromArguments:(NSDictionary*)arguments key:(NSString*)key;
- (int)intFromArguments:(NSDictionary*)arguments key:(NSString*)key;
@end

#pragma mark - 实现

@implementation WhiteboardMacosPlugin {
  NSObject<FlutterPluginRegistrar>* _registrar;
  WbShortcutPlugin* _shortcut;
  WbTrayPlugin* _tray;
  WbScreenCapture* _capture;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:@"whiteboard/macos"
                                 binaryMessenger:[registrar messenger]];
  WhiteboardMacosPlugin* instance =
      [[WhiteboardMacosPlugin alloc] initWithRegistrar:registrar channel:channel];
  // addMethodCallDelegate 的 handler block 强持有 instance，
  // instance 强持有子模块，生命周期随 engine messenger。
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar
                          channel:(FlutterMethodChannel*)channel {
  self = [super init];
  if (self) {
    _registrar = registrar;
    _shortcut = [[WbShortcutPlugin alloc] initWithChannel:channel];
    _tray = [[WbTrayPlugin alloc] initWithChannel:channel];
    _capture = [[WbScreenCapture alloc] init];
  }
  return self;
}

- (void)dealloc {
  // 释放原生资源：注销 Carbon 热键、移除状态栏项（幂等，主线程释放）。
  [_shortcut dispose];
  [_tray dispose];
}

#pragma mark - 方法分发

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSString* method = call.method;
  NSDictionary* arguments = nil;
  if ([call.arguments isKindOfClass:[NSDictionary class]]) {
    arguments = call.arguments;
  }

  if ([method hasPrefix:@"window."]) {
    [self handleWindowMethod:method arguments:arguments result:result];
  } else if ([method hasPrefix:@"shortcut."]) {
    [self handleShortcutMethod:method arguments:arguments result:result];
  } else if ([method hasPrefix:@"tray."]) {
    [self handleTrayMethod:method arguments:arguments result:result];
  } else if ([method hasPrefix:@"capture."]) {
    [self handleCaptureMethod:method arguments:arguments result:result];
  } else {
    result(FlutterMethodNotImplemented);
  }
}

#pragma mark - window.*

- (void)handleWindowMethod:(NSString*)method
                 arguments:(NSDictionary*)arguments
                    result:(FlutterResult)result {
  NSWindow* window = [self requireWindowForResult:result];
  if (window == nil) {
    return;
  }
  if ([method isEqualToString:@"window.setTransparent"]) {
    [WbWindowPlugin setTransparent:[self boolFromArguments:arguments key:@"transparent"]
                         forWindow:window];
  } else if ([method isEqualToString:@"window.setAlwaysOnTop"]) {
    [WbWindowPlugin setAlwaysOnTop:[self boolFromArguments:arguments key:@"onTop"]
                         forWindow:window];
  } else if ([method isEqualToString:@"window.setIgnoreMouseEvents"]) {
    [WbWindowPlugin setIgnoreMouseEvents:[self boolFromArguments:arguments key:@"ignore"]
                                 forward:[self boolFromArguments:arguments key:@"forward"]
                               forWindow:window];
  } else if ([method isEqualToString:@"window.setFullscreen"]) {
    [WbWindowPlugin setFullscreen:[self boolFromArguments:arguments key:@"fullscreen"]
                        forWindow:window];
  } else if ([method isEqualToString:@"window.setPosition"]) {
    [WbWindowPlugin setPositionX:[self intFromArguments:arguments key:@"x"]
                               y:[self intFromArguments:arguments key:@"y"]
                       forWindow:window];
  } else if ([method isEqualToString:@"window.setSize"]) {
    [WbWindowPlugin setContentSizeWidth:[self intFromArguments:arguments key:@"width"]
                                 height:[self intFromArguments:arguments key:@"height"]
                              forWindow:window];
  } else {
    result(FlutterMethodNotImplemented);
    return;
  }
  result(nil);
}

#pragma mark - shortcut.*

- (void)handleShortcutMethod:(NSString*)method
                   arguments:(NSDictionary*)arguments
                      result:(FlutterResult)result {
  if ([method isEqualToString:@"shortcut.register"]) {
    NSString* accelerator = arguments[@"accelerator"];
    NSString* identifier = arguments[@"id"];
    if (![accelerator isKindOfClass:[NSString class]] || accelerator.length == 0 ||
        ![identifier isKindOfClass:[NSString class]] || identifier.length == 0) {
      result([FlutterError errorWithCode:@"invalid-accelerator"
                                 message:@"accelerator 与 id 必须为非空字符串"
                                 details:arguments]);
      return;
    }
    // 解析失败 / 注册失败均返回 FlutterError（code = invalid-accelerator /
    // register-failed）；成功返回 nil。
    result([_shortcut registerAccelerator:accelerator identifier:identifier]);
  } else if ([method isEqualToString:@"shortcut.unregister"]) {
    NSString* identifier = arguments[@"id"];
    if ([identifier isKindOfClass:[NSString class]] && identifier.length > 0) {
      [_shortcut unregisterIdentifier:identifier];
    }
    result(nil);
  } else if ([method isEqualToString:@"shortcut.unregisterAll"]) {
    [_shortcut unregisterAll];
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

#pragma mark - tray.*

- (void)handleTrayMethod:(NSString*)method
               arguments:(NSDictionary*)arguments
                  result:(FlutterResult)result {
  if ([method isEqualToString:@"tray.setIcon"]) {
    NSString* iconPath = arguments[@"iconPath"];
    if ([iconPath isKindOfClass:[NSString class]] && iconPath.length > 0) {
      [_tray setIcon:iconPath];
    }
    result(nil);
  } else if ([method isEqualToString:@"tray.setTooltip"]) {
    NSString* tooltip = arguments[@"tooltip"];
    if ([tooltip isKindOfClass:[NSString class]]) {
      [_tray setTooltip:tooltip];
    }
    result(nil);
  } else if ([method isEqualToString:@"tray.setMenu"]) {
    NSArray<NSDictionary*>* items = nil;
    if ([arguments[@"items"] isKindOfClass:[NSArray class]]) {
      items = arguments[@"items"];
    }
    [_tray setMenuItems:items];
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

#pragma mark - capture.*

- (void)handleCaptureMethod:(NSString*)method
                  arguments:(NSDictionary*)arguments
                     result:(FlutterResult)result {
  if ([method isEqualToString:@"capture.captureDisplay"]) {
    NSNumber* displayId = arguments[@"displayId"];
    uint32_t value =
        [displayId isKindOfClass:[NSNumber class]] ? displayId.unsignedIntValue : (uint32_t)-1;
    result([_capture captureDisplay:value]);
  } else if ([method isEqualToString:@"capture.isAvailable"]) {
    result(@([_capture isAvailable]));
  } else {
    result(FlutterMethodNotImplemented);
  }
}

#pragma mark - 窗口获取

/// 获取承载 Flutter 内容的主窗口（供 window.* 使用）。
///
/// 方案（按可靠性排序）：
///   1. registrar.view.window —— FlutterView 与其宿主 NSWindow 的关联最
///      直接，不依赖 key/main 窗口的瞬时状态（本插件弹出菜单 / 面板时
///      mainWindow 可能变化）；
///   2. NSApp.mainWindow / keyWindow 兜底（view 尚未附着等场景）；
///   3. 遍历 NSApp.windows 取第一个可见且带 contentViewController 的窗口。
- (NSWindow*)flutterWindow {
  NSWindow* window = _registrar.view.window;
  if (window != nil) {
    return window;
  }
  window = [NSApp mainWindow];
  if (window == nil) {
    window = [NSApp keyWindow];
  }
  if (window != nil) {
    return window;
  }
  for (NSWindow* candidate in [NSApp windows]) {
    if (candidate.contentViewController != nil && candidate.isVisible) {
      return candidate;
    }
  }
  return nil;
}

/// 获取窗口；失败时以错误码 `no-window` 回复 Dart 并返回 nil。
- (NSWindow*)requireWindowForResult:(FlutterResult)result {
  NSWindow* window = [self flutterWindow];
  if (window == nil) {
    result([FlutterError errorWithCode:@"no-window"
                               message:@"未找到承载 Flutter 内容的窗口"
                               details:nil]);
  }
  return window;
}

#pragma mark - 参数取值

- (BOOL)boolFromArguments:(NSDictionary*)arguments key:(NSString*)key {
  NSNumber* value = arguments[key];
  return [value isKindOfClass:[NSNumber class]] ? value.boolValue : NO;
}

- (int)intFromArguments:(NSDictionary*)arguments key:(NSString*)key {
  NSNumber* value = arguments[key];
  return [value isKindOfClass:[NSNumber class]] ? value.intValue : 0;
}

@end
