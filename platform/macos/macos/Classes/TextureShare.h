//
// TextureShare.h
// IOSurface 纹理共享预留骨架。
//
// 规划：以 IOSurface 作为共享纹理载体，与 Flutter 外部纹理
// （FlutterTexture / FlutterTextureRegistry）对接，让捕获画面 /
// 批注图层走 GPU 零拷贝路径，替代逐帧 readback。
// 当前 Wave 仅交付能力查询（不接入方法通道，通道协议扩展须走
// 契约评审，详见《透明批注模式技术方案》§8.4 与《Flutter + C++
// 工程结构设计》§6.2 的 texture_share 规划）。
//

#import <Foundation/Foundation.h>

/// 纹理共享能力查询（预留）。
@interface WbTextureShare : NSObject

/// IOSurface 纹理共享是否可用。
///
/// 当前实现：IOSurface 在所有受支持系统（>= macOS 10.14）均存在，
/// 返回 YES；真正的纹理通道（共享表面创建 / 注册 FlutterTexture）
/// 在后续 Wave 接入。
+ (BOOL)isTextureShareSupported;

@end
