//
// ScreenCapture.mm
// 屏幕捕获实现（Objective-C++ / Quartz）。
//
// 流程：CGGetActiveDisplayList 校验显示器 → CGDisplayCreateImage 抓取
// → 重绘到 BGRA（kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst）
// → FlutterStandardTypedData 打包 {bytes,width,height,stride}。
// 任何一步失败返回 nil（Dart 侧映射为“不可用/未授权”）。
//

#import "ScreenCapture.h"

#import <CoreGraphics/CoreGraphics.h>
#import <FlutterMacOS/FlutterMacOS.h>

/// 活动显示器列表的栈缓冲上限（超出部分不参与 id 校验；
/// 主流桌面场景 < 8，16 足够）。
static const uint32_t kWbMaxDisplays = 16;

#pragma mark - 私有接口

@interface WbScreenCapture ()
- (CGDirectDisplayID)resolveDisplay:(uint32_t)displayId;
- (nullable NSDictionary*)dictionaryFromImage:(CGImageRef)image;
@end

#pragma mark - 实现

@implementation WbScreenCapture

- (BOOL)isAvailable {
  // Quartz 抓屏 API 在所有受支持的系统（>= macOS 10.14）可用；
  // 实际捕获需要“屏幕录制”权限（macOS 10.15+），由上层在捕获前
  // 校验/引导用户授权（《安全与合规设计》§7.8：不自动截屏）。
  return YES;
}

- (NSDictionary*)captureDisplay:(uint32_t)displayId {
  CGDirectDisplayID display = [self resolveDisplay:displayId];
  if (display == kCGNullDirectDisplay) {
    return nil;
  }
  // 未授权“屏幕录制”时视系统版本可能返回 NULL / 空内容，统一按失败处理。
  CGImageRef image = CGDisplayCreateImage(display);
  if (image == NULL) {
    return nil;
  }
  NSDictionary* frame = [self dictionaryFromImage:image];
  CGImageRelease(image);
  return frame;
}

#pragma mark - 内部

/// displayId 校验：(uint32_t)-1 / 0 回退主显示器；
/// 未知 id 返回 kCGNullDirectDisplay（上层映射为 nil）。
- (CGDirectDisplayID)resolveDisplay:(uint32_t)displayId {
  if (displayId == 0 || displayId == (uint32_t)-1) {
    return CGMainDisplayID();
  }
  CGDirectDisplayID displays[kWbMaxDisplays];
  uint32_t fetched = 0;
  CGError error = CGGetActiveDisplayList(kWbMaxDisplays, displays, &fetched);
  if (error != kCGErrorSuccess || fetched == 0) {
    return kCGNullDirectDisplay;
  }
  for (uint32_t index = 0; index < fetched; index++) {
    if ((uint32_t)displays[index] == displayId) {
      return displays[index];
    }
  }
  return kCGNullDirectDisplay;
}

/// CGImage → BGRA 字典（{bytes,width,height,stride}）；失败返回 nil。
- (NSDictionary*)dictionaryFromImage:(CGImageRef)image {
  size_t width = CGImageGetWidth(image);
  size_t height = CGImageGetHeight(image);
  if (width == 0 || height == 0) {
    return nil;
  }
  size_t stride = width * 4;
  NSMutableData* pixelData = [NSMutableData dataWithLength:stride * height];
  if (pixelData == nil) {
    return nil;
  }
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  if (colorSpace == NULL) {
    return nil;
  }
  // BGRA 内存布局：32 位小端 + alpha 在前（与 Dart 侧文档一致）。
  CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
  CGContextRef context = CGBitmapContextCreate(pixelData.mutableBytes,
                                               width,
                                               height,
                                               8,
                                               stride,
                                               colorSpace,
                                               bitmapInfo);
  CGColorSpaceRelease(colorSpace);
  if (context == NULL) {
    return nil;
  }
  CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
  CGContextRelease(context);

  FlutterStandardTypedData* typedData =
      [FlutterStandardTypedData typedDataWithBytes:pixelData];
  return @{
    @"bytes": typedData,
    @"width": @(width),
    @"height": @(height),
    @"stride": @(stride),
  };
}

@end
