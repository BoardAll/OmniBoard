//
// ShortcutPlugin.mm
// 全局快捷键实现（Carbon RegisterEventHotKey）。
//
// 数据结构：
//   字符串 id ⇄ Carbon 热键数字 id（UInt32）⇄ EventHotKeyRef；
// 事件处理：
//   应用事件目标上安装一个 kEventHotKeyPressed 处理器，用 FourCC
//   签名过滤本插件注册的热键（同目标上可能存在其他库的热键），
//   命中后经主队列将 'shortcut.triggered' 回传 Dart。
//

#import "ShortcutPlugin.h"

#import <Carbon/Carbon.h>

/// 热键签名（FourCC 'wbht'）：过滤掉应用事件目标上其他来源的热键事件。
static const OSType kWbHotKeySignature = 'wbht';

/// 主键 token（已大写）→ Carbon 虚拟键码；未收录返回 nil。
static NSNumber* WbKeyCodeByToken(NSString* token);

/// Carbon 热键按下回调；userData = WbShortcutPlugin 实例。
static OSStatus WbHotKeyPressedHandler(EventHandlerCallRef nextHandler,
                                       EventRef event,
                                       void* userData);

#pragma mark - 私有接口

@interface WbShortcutPlugin ()
- (BOOL)ensureEventHandler:(FlutterError**)error;
- (void)unregisterHotKeyId:(UInt32)hotKeyId;
- (void)dispatchTriggerForHotKeyId:(UInt32)hotKeyId;
- (BOOL)parseAccelerator:(NSString*)accelerator
                 keyCode:(UInt32*)outKeyCode
               modifiers:(UInt32*)outModifiers;
- (BOOL)keyCodeForToken:(NSString*)token keyCode:(UInt32*)outKeyCode;
@end

#pragma mark - 实现

@implementation WbShortcutPlugin {
  FlutterMethodChannel* _channel;
  /// 字符串 id → Carbon 热键数字 id。
  NSMutableDictionary<NSString*, NSNumber*>* _identifierToHotKeyId;
  /// Carbon 热键数字 id → 字符串 id。
  NSMutableDictionary<NSNumber*, NSString*>* _hotKeyIdToIdentifier;
  /// Carbon 热键数字 id → EventHotKeyRef（NSValue 包装）。
  NSMutableDictionary<NSNumber*, NSValue*>* _hotKeyIdToRef;
  /// 自增热键数字 id（从 1 开始，0 保留）。
  UInt32 _nextHotKeyId;
  /// 应用事件目标上的键盘事件处理器。
  EventHandlerRef _eventHandlerRef;
}

- (instancetype)initWithChannel:(FlutterMethodChannel*)channel {
  self = [super init];
  if (self) {
    _channel = channel;
    _identifierToHotKeyId = [[NSMutableDictionary alloc] init];
    _hotKeyIdToIdentifier = [[NSMutableDictionary alloc] init];
    _hotKeyIdToRef = [[NSMutableDictionary alloc] init];
    _nextHotKeyId = 1;
    _eventHandlerRef = NULL;
  }
  return self;
}

- (void)dealloc {
  [self dispose];
}

#pragma mark - 注册 / 注销

- (FlutterError*)registerAccelerator:(NSString*)accelerator
                          identifier:(NSString*)identifier {
  if (accelerator.length == 0 || identifier.length == 0) {
    return [FlutterError errorWithCode:@"invalid-accelerator"
                               message:@"accelerator 与 id 必须为非空字符串"
                               details:accelerator];
  }

  UInt32 keyCode = 0;
  UInt32 modifiers = 0;
  if (![self parseAccelerator:accelerator keyCode:&keyCode modifiers:&modifiers]) {
    return [FlutterError
        errorWithCode:@"invalid-accelerator"
              message:@"无法解析加速键（支持 Ctrl/Alt/Shift/Cmd + 单字符或 F1…F12/Space/Tab 等）"
              details:accelerator];
  }

  FlutterError* installError = nil;
  if (![self ensureEventHandler:&installError]) {
    return installError;
  }

  // 幂等：同 id 重复注册时先注销旧绑定（含旧加速键组合）。
  if (_identifierToHotKeyId[identifier] != nil) {
    [self unregisterIdentifier:identifier];
  }

  UInt32 hotKeyId = _nextHotKeyId;
  _nextHotKeyId += 1;
  if (_nextHotKeyId == 0) {
    _nextHotKeyId = 1;  // 防回绕：0 保留。
  }

  EventHotKeyID carbonId = {kWbHotKeySignature, hotKeyId};
  EventHotKeyRef hotKeyRef = NULL;
  OSStatus status = RegisterEventHotKey(keyCode, modifiers, carbonId,
                                        GetApplicationEventTarget(), 0, &hotKeyRef);
  if (status != noErr || hotKeyRef == NULL) {
    return [FlutterError
        errorWithCode:@"register-failed"
              message:[NSString
                          stringWithFormat:@"RegisterEventHotKey 失败（OSStatus=%d，组合可能已被占用）",
                                           (int)status]
              details:accelerator];
  }

  _identifierToHotKeyId[identifier] = @(hotKeyId);
  _hotKeyIdToIdentifier[@(hotKeyId)] = identifier;
  _hotKeyIdToRef[@(hotKeyId)] = [NSValue valueWithPointer:(const void*)hotKeyRef];
  return nil;
}

- (void)unregisterIdentifier:(NSString*)identifier {
  if (identifier.length == 0) {
    return;
  }
  NSNumber* number = _identifierToHotKeyId[identifier];
  if (number == nil) {
    return;
  }
  [self unregisterHotKeyId:number.unsignedIntValue];
}

- (void)unregisterAll {
  // allKeys 返回快照，避免迭代中修改字典。
  NSArray<NSNumber*>* keys = _hotKeyIdToRef.allKeys;
  for (NSNumber* key in keys) {
    [self unregisterHotKeyId:key.unsignedIntValue];
  }
}

- (void)unregisterHotKeyId:(UInt32)hotKeyId {
  NSNumber* key = @(hotKeyId);
  NSValue* refValue = _hotKeyIdToRef[key];
  if (refValue != nil) {
    EventHotKeyRef hotKeyRef = (EventHotKeyRef)refValue.pointerValue;
    if (hotKeyRef != NULL) {
      UnregisterEventHotKey(hotKeyRef);
    }
    [_hotKeyIdToRef removeObjectForKey:key];
  }
  NSString* identifier = _hotKeyIdToIdentifier[key];
  if (identifier != nil) {
    [_hotKeyIdToIdentifier removeObjectForKey:key];
    [_identifierToHotKeyId removeObjectForKey:identifier];
  }
}

- (void)dispose {
  [self unregisterAll];
  if (_eventHandlerRef != NULL) {
    RemoveEventHandler(_eventHandlerRef);
    _eventHandlerRef = NULL;
  }
}

#pragma mark - 事件处理

- (void)dispatchTriggerForHotKeyId:(UInt32)hotKeyId {
  NSString* identifier = _hotKeyIdToIdentifier[@(hotKeyId)];
  if (identifier.length == 0) {
    return;
  }
  FlutterMethodChannel* channel = _channel;
  if (channel == nil) {
    return;
  }
  // 事件回调可能在嵌套 run loop 中触发；统一切回主队列再回传，
  // 保证与通道调用同线程、事件顺序稳定。
  dispatch_async(dispatch_get_main_queue(), ^{
    [channel invokeMethod:@"shortcut.triggered" arguments:@{@"id": identifier}];
  });
}

/// 安装应用事件目标上的 kEventHotKeyPressed 处理器（首次注册时）。
- (BOOL)ensureEventHandler:(FlutterError**)error {
  if (_eventHandlerRef != NULL) {
    return YES;
  }
  EventTypeSpec eventType;
  eventType.eventClass = kEventClassKeyboard;
  eventType.eventKind = kEventHotKeyPressed;
  OSStatus status = InstallEventHandler(GetApplicationEventTarget(),
                                        &WbHotKeyPressedHandler,
                                        1,
                                        &eventType,
                                        (__bridge void*)self,
                                        &_eventHandlerRef);
  if (status != noErr) {
    _eventHandlerRef = NULL;
    if (error != NULL) {
      *error = [FlutterError
          errorWithCode:@"register-failed"
                message:[NSString stringWithFormat:@"InstallEventHandler 失败（OSStatus=%d）",
                                                   (int)status]
                details:nil];
    }
    return NO;
  }
  return YES;
}

#pragma mark - 加速键解析

/// 主键 token（已大写）→ Carbon 虚拟键码表。
static NSDictionary<NSString*, NSNumber*>* WbKeyCodeMap(void) {
  static NSDictionary<NSString*, NSNumber*>* map = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    map = @{
      // 字母（ISO 键盘布局的 ANSI 位置键码）。
      @"A": @(kVK_ANSI_A), @"B": @(kVK_ANSI_B), @"C": @(kVK_ANSI_C),
      @"D": @(kVK_ANSI_D), @"E": @(kVK_ANSI_E), @"F": @(kVK_ANSI_F),
      @"G": @(kVK_ANSI_G), @"H": @(kVK_ANSI_H), @"I": @(kVK_ANSI_I),
      @"J": @(kVK_ANSI_J), @"K": @(kVK_ANSI_K), @"L": @(kVK_ANSI_L),
      @"M": @(kVK_ANSI_M), @"N": @(kVK_ANSI_N), @"O": @(kVK_ANSI_O),
      @"P": @(kVK_ANSI_P), @"Q": @(kVK_ANSI_Q), @"R": @(kVK_ANSI_R),
      @"S": @(kVK_ANSI_S), @"T": @(kVK_ANSI_T), @"U": @(kVK_ANSI_U),
      @"V": @(kVK_ANSI_V), @"W": @(kVK_ANSI_W), @"X": @(kVK_ANSI_X),
      @"Y": @(kVK_ANSI_Y), @"Z": @(kVK_ANSI_Z),
      // 数字。
      @"0": @(kVK_ANSI_0), @"1": @(kVK_ANSI_1), @"2": @(kVK_ANSI_2),
      @"3": @(kVK_ANSI_3), @"4": @(kVK_ANSI_4), @"5": @(kVK_ANSI_5),
      @"6": @(kVK_ANSI_6), @"7": @(kVK_ANSI_7), @"8": @(kVK_ANSI_8),
      @"9": @(kVK_ANSI_9),
      // 符号。
      @"-": @(kVK_ANSI_Minus), @"=": @(kVK_ANSI_Equal),
      @"[": @(kVK_ANSI_LeftBracket), @"]": @(kVK_ANSI_RightBracket),
      @";": @(kVK_ANSI_Semicolon), @"'": @(kVK_ANSI_Quote),
      @",": @(kVK_ANSI_Comma), @".": @(kVK_ANSI_Period), @"/": @(kVK_ANSI_Slash),
      @"\\": @(kVK_ANSI_Backslash), @"`": @(kVK_ANSI_Grave),
      // 功能键。
      @"F1": @(kVK_F1), @"F2": @(kVK_F2), @"F3": @(kVK_F3), @"F4": @(kVK_F4),
      @"F5": @(kVK_F5), @"F6": @(kVK_F6), @"F7": @(kVK_F7), @"F8": @(kVK_F8),
      @"F9": @(kVK_F9), @"F10": @(kVK_F10), @"F11": @(kVK_F11), @"F12": @(kVK_F12),
      // 具名键。
      @"SPACE": @(kVK_Space), @"TAB": @(kVK_Tab),
      @"ENTER": @(kVK_Return), @"RETURN": @(kVK_Return),
      @"ESCAPE": @(kVK_Escape), @"ESC": @(kVK_Escape),
      @"DELETE": @(kVK_Delete), @"BACKSPACE": @(kVK_Delete),
      @"UP": @(kVK_UpArrow), @"DOWN": @(kVK_DownArrow),
      @"LEFT": @(kVK_LeftArrow), @"RIGHT": @(kVK_RightArrow),
      @"HOME": @(kVK_Home), @"END": @(kVK_End),
      @"PAGEUP": @(kVK_PageUp), @"PAGEDOWN": @(kVK_PageDown),
    };
  });
  return map;
}

static NSNumber* WbKeyCodeByToken(NSString* token) {
  return WbKeyCodeMap()[token];
}

/// 解析加速键字符串为 Carbon 键码 + 修饰符；解析失败返回 NO。
- (BOOL)parseAccelerator:(NSString*)accelerator
                 keyCode:(UInt32*)outKeyCode
               modifiers:(UInt32*)outModifiers {
  if (outKeyCode == NULL || outModifiers == NULL) {
    return NO;
  }
  NSArray<NSString*>* parts = [accelerator componentsSeparatedByString:@"+"];
  UInt32 modifiers = 0;
  NSString* keyToken = nil;
  for (NSString* rawPart in parts) {
    NSString* part =
        [rawPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (part.length == 0) {
      return NO;
    }
    NSString* lower = part.lowercaseString;
    if ([lower isEqualToString:@"ctrl"] || [lower isEqualToString:@"control"]) {
      modifiers |= controlKey;
    } else if ([lower isEqualToString:@"shift"]) {
      modifiers |= shiftKey;
    } else if ([lower isEqualToString:@"alt"] || [lower isEqualToString:@"option"]) {
      modifiers |= optionKey;
    } else if ([lower isEqualToString:@"cmd"] || [lower isEqualToString:@"command"] ||
               [lower isEqualToString:@"meta"] || [lower isEqualToString:@"win"] ||
               [lower isEqualToString:@"super"] || [part isEqualToString:@"⌘"]) {
      modifiers |= cmdKey;
    } else if (keyToken == nil) {
      keyToken = part;
    } else {
      return NO;  // 出现第二个主键 → 非法。
    }
  }
  if (keyToken == nil) {
    return NO;
  }
  UInt32 keyCode = 0;
  if (![self keyCodeForToken:keyToken keyCode:&keyCode]) {
    return NO;
  }
  // 不强制要求修饰键（与 Windows RegisterHotKey 的宽容度一致）；
  // 无修饰键的全局热键会抢占普通输入，是否禁止由上层策略决定。
  *outKeyCode = keyCode;
  *outModifiers = modifiers;
  return YES;
}

/// 主键 token → 虚拟键码（大小写不敏感）。
- (BOOL)keyCodeForToken:(NSString*)token keyCode:(UInt32*)outKeyCode {
  if (token.length == 0 || outKeyCode == NULL) {
    return NO;
  }
  NSNumber* number = WbKeyCodeByToken(token.uppercaseString);
  if (number == nil) {
    return NO;
  }
  *outKeyCode = number.unsignedIntValue;
  return YES;
}

@end

#pragma mark - Carbon 回调

static OSStatus WbHotKeyPressedHandler(EventHandlerCallRef nextHandler,
                                       EventRef event,
                                       void* userData) {
  (void)nextHandler;
  EventHotKeyID hotKeyId = {0, 0};
  OSStatus status = GetEventParameter(event,
                                      kEventParamDirectObject,
                                      typeEventHotKeyID,
                                      NULL,
                                      sizeof(hotKeyId),
                                      NULL,
                                      &hotKeyId);
  if (status == noErr && hotKeyId.signature == kWbHotKeySignature) {
    WbShortcutPlugin* plugin = (__bridge WbShortcutPlugin*)userData;
    [plugin dispatchTriggerForHotKeyId:hotKeyId.id];
  }
  return noErr;
}
