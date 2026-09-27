//
// ScreenCapture.h
// 屏幕捕获（Quartz）：CGGetActiveDisplayList + CGDisplayCreateImage。
//
// 对应 Dart `WbScreenCapturePlugin` / `MacosScreenCapturePlugin`
// （通道 'capture.*'）。输出 BGRA 原始像素，由 Dart 侧编码/入库。
// 合规（《安全与合规设计》§7.8）：
//   - 不自动截屏、不自动上传，捕获动作须由用户明确触发；
//   - macOS 10.15+ 需要“屏幕录制”权限，未授权时捕获返回 nil，
//     授权流程由上层 UI 负责（本插件不弹窗、不申请）。
//

#import <Foundation/Foundation.h>

/// 屏幕捕获器（无状态）。
@interface WbScreenCapture : NSObject

/// 捕获显示器画面。
///
/// [displayId] 为 CGDirectDisplayID；(uint32_t)-1 / 0 / 未知 id 时
/// 回退主显示器。成功返回 {bytes: FlutterStandardTypedData(BGRA),
/// width, height, stride}；失败（未授权 / 系统错误）返回 nil。
- (nullable NSDictionary*)captureDisplay:(uint32_t)displayId;

/// 捕获能力是否可用（平台 API 存在；权限由上层在捕获前校验/请求）。
- (BOOL)isAvailable;

@end
