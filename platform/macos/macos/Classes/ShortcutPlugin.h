//
// ShortcutPlugin.h
// 全局快捷键（Carbon RegisterEventHotKey）。
//
// 方案说明：使用 Carbon RegisterEventHotKey 注册系统级热键，通过应用
// 事件目标（GetApplicationEventTarget）接收 kEventHotKeyPressed。
// 相比 CGEventTap，该方案无需“辅助功能”（Accessibility）权限，
// 回调在主线程事件循环中触发，适合“一键切换批注模式”场景。
// 对应 Dart `WbShortcutPlugin` / `MacosShortcutPlugin`（通道 'shortcut.*'）。
//

#import <FlutterMacOS/FlutterMacOS.h>

/// 全局快捷键注册器（同一时刻只应存在一个实例）。
@interface WbShortcutPlugin : NSObject

/// 以方法通道初始化（触发事件通过 `shortcut.triggered` 回传 Dart）。
- (instancetype)initWithChannel:(FlutterMethodChannel*)channel;

/// 注册全局快捷键。
///
/// [accelerator] 形如 `Ctrl+Shift+J` / `Cmd+F1`；修饰键支持
/// Ctrl / Alt / Shift / Cmd（⌘）；主键为单字符或 F1…F12 / Space /
/// Tab / Enter / Escape / Delete / 方向键等。
///
/// 成功返回 nil；失败返回 [FlutterError]：
/// - 解析失败：code = `invalid-accelerator`；
/// - 系统注册失败（组合被占用等）：code = `register-failed`。
- (nullable FlutterError*)registerAccelerator:(NSString*)accelerator
                                   identifier:(NSString*)identifier;

/// 注销单个快捷键（未注册时静默返回）。
- (void)unregisterIdentifier:(NSString*)identifier;

/// 注销全部快捷键。
- (void)unregisterAll;

/// 释放原生资源（注销全部热键并移除事件处理器）；幂等，主线程调用。
- (void)dispose;

@end
