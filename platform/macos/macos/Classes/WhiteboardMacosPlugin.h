//
// WhiteboardMacosPlugin.h
// Whiteboard macOS 平台插件入口。
//
// 注册 FlutterMethodChannel 'whiteboard/macos'，分发 window.* / shortcut.* /
// tray.* / capture.* 方法调用，并将原生事件（'shortcut.triggered' /
// 'tray.clicked'）回传 Dart 侧；Dart 侧对应 lib/src/ 下的 Macos* 包装类
// （通道名与参数见《Flutter + C++ 工程结构设计》§6.2 / §6.5）。
//

#import <FlutterMacOS/FlutterMacOS.h>

/// Whiteboard macOS 平台插件（对应 Dart 侧 Macos* 系列包装类）。
@interface WhiteboardMacosPlugin : NSObject <FlutterPlugin>
@end
