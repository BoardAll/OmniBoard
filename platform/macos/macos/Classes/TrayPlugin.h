//
// TrayPlugin.h
// 系统托盘（macOS 状态栏）：NSStatusBar statusItem + NSMenu。
//
// 对应 Dart `WbTrayPlugin` / `MacosTrayPlugin`（通道 'tray.*'）：
//   tray.setIcon    → 状态栏按钮图像（建议 template 风格 PNG）；
//   tray.setTooltip → 按钮悬停提示；
//   tray.setMenu    → 右键菜单整体替换（separator / checkbox / enabled 映射）；
//   点击菜单项       → 'tray.clicked' {id} 回传 Dart。
// 所有方法必须在主线程调用。
//

#import <FlutterMacOS/FlutterMacOS.h>

/// 托盘（状态栏项）管理器（同一时刻只应存在一个实例）。
@interface WbTrayPlugin : NSObject

/// 以方法通道初始化（点击事件通过 `tray.clicked` 回传 Dart）。
- (instancetype)initWithChannel:(FlutterMethodChannel*)channel;

/// 设置托盘图标（文件路径；空路径忽略）。macOS 建议 PNG/TIFF，
/// .ico 不受支持时图像加载失败将保留现有图标。
- (void)setIcon:(nullable NSString*)iconPath;

/// 设置悬停提示。
- (void)setTooltip:(nullable NSString*)tooltip;

/// 设置右键菜单（整体替换，元素为 Dart `WbTrayMenuItem.toMap` 字典）。
- (void)setMenuItems:(nullable NSArray<NSDictionary*>*)items;

/// 清理资源（移除状态栏项）；幂等，主线程调用。
- (void)dispose;

@end
