//
// TrayPlugin.mm
// 系统托盘实现（Objective-C++ / Cocoa）。
//
// 结构：NSStatusBar systemStatusBar 创建 NSStatusItem；
//   - 图标：statusItem.button.image（template 语义，见 setIcon: 注释）；
//   - 菜单：NSMenuItem 序列（separator / checkbox / enabled 映射），
//     点击经 target/action 回调，用 representedObject 携带稳定 id，
//     通过 'tray.clicked' {id} 回传 Dart。
//

#import "TrayPlugin.h"

#pragma mark - 私有接口

@interface WbTrayPlugin ()
- (nullable NSStatusItem*)ensureStatusItem;
- (void)menuItemClicked:(NSMenuItem*)sender;
@end

#pragma mark - 实现

@implementation WbTrayPlugin {
  FlutterMethodChannel* _channel;
  NSStatusItem* _statusItem;
}

- (instancetype)initWithChannel:(FlutterMethodChannel*)channel {
  self = [super init];
  if (self) {
    _channel = channel;
  }
  return self;
}

- (void)dealloc {
  NSStatusItem* item = _statusItem;
  if (item == nil) {
    return;
  }
  if ([NSThread isMainThread]) {
    [[NSStatusBar systemStatusBar] removeStatusItem:item];
  } else {
    // 兜底：非主线程释放时切回主队列移除（AppKit 要求主线程操作状态栏）。
    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSStatusBar systemStatusBar] removeStatusItem:item];
    });
  }
}

#pragma mark - 通道动作

- (void)setIcon:(NSString*)iconPath {
  [self ensureStatusItem];
  if (_statusItem == nil || iconPath.length == 0) {
    return;
  }
  NSImage* image = [[NSImage alloc] initWithContentsOfFile:iconPath];
  if (image == nil) {
    // 图像加载失败（路径不存在 / 格式不支持）时保留现有图标。
    return;
  }
  // template = YES：按 alpha 通道自适应浅色 / 深色菜单栏，
  // 建议传入单色 + 透明背景的 PNG；彩色图标可改用非 template 方案。
  image.template = YES;
  _statusItem.button.image = image;
}

- (void)setTooltip:(NSString*)tooltip {
  [self ensureStatusItem];
  if (_statusItem == nil) {
    return;
  }
  _statusItem.button.toolTip = tooltip;
}

- (void)setMenuItems:(NSArray<NSDictionary*>*)items {
  [self ensureStatusItem];
  if (_statusItem == nil) {
    return;
  }
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Whiteboard"];
  // 可用性完全由 Dart 侧数据决定，禁用 AppKit 对无 action 项的自动禁用。
  menu.autoenablesItems = NO;
  NSArray* rawItems = [items isKindOfClass:[NSArray class]] ? items : @[];
  for (id rawItem in rawItems) {
    if (![rawItem isKindOfClass:[NSDictionary class]]) {
      continue;
    }
    NSDictionary* item = (NSDictionary*)rawItem;
    NSString* type = item[@"type"];
    if ([type isKindOfClass:[NSString class]] && [type isEqualToString:@"separator"]) {
      [menu addItem:[NSMenuItem separatorItem]];
      continue;
    }
    NSString* identifier = item[@"id"];
    NSString* label = item[@"label"];
    if (![label isKindOfClass:[NSString class]] || label.length == 0) {
      label = [identifier isKindOfClass:[NSString class]] ? identifier : @"";
    }
    NSMenuItem* menuItem = [[NSMenuItem alloc] initWithTitle:label
                                                      action:@selector(menuItemClicked:)
                                               keyEquivalent:@""];
    menuItem.target = self;
    menuItem.representedObject =
        [identifier isKindOfClass:[NSString class]] ? identifier : nil;
    NSNumber* enabled = item[@"enabled"];
    menuItem.enabled = [enabled isKindOfClass:[NSNumber class]] ? enabled.boolValue : YES;
    NSNumber* checked = item[@"checked"];
    menuItem.state = ([checked isKindOfClass:[NSNumber class]] && checked.boolValue)
                         ? NSControlStateValueOn
                         : NSControlStateValueOff;
    [menu addItem:menuItem];
  }
  // 状态栏项直接绑定菜单（NSStatusItem 强持有 menu）：
  // 左键 / 右键点击均弹出（macOS 状态栏惯例）。
  _statusItem.menu = menu;
}

- (void)dispose {
  if (_statusItem == nil) {
    return;
  }
  NSStatusItem* item = _statusItem;
  _statusItem = nil;
  [[NSStatusBar systemStatusBar] removeStatusItem:item];
}

#pragma mark - 内部

- (NSStatusItem*)ensureStatusItem {
  if (_statusItem != nil) {
    return _statusItem;
  }
  _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
  return _statusItem;
}

- (void)menuItemClicked:(NSMenuItem*)sender {
  id represented = sender.representedObject;
  if (![represented isKindOfClass:[NSString class]]) {
    return;
  }
  NSString* identifier = (NSString*)represented;
  if (identifier.length == 0 || _channel == nil) {
    return;
  }
  // 菜单 action 在主线程触发；直接回传即可保证与通道调用同线程。
  [_channel invokeMethod:@"tray.clicked" arguments:@{@"id": identifier}];
}

@end
