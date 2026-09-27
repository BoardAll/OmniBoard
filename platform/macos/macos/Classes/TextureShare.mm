//
// TextureShare.mm
// IOSurface 纹理共享骨架实现。
//
// 仅做编译期 / 运行期能力判定，不创建共享表面、不注册 FlutterTexture。
//

#import "TextureShare.h"

#if __has_include(<IOSurface/IOSurface.h>)
#import <IOSurface/IOSurface.h>
#define WB_HAS_IOSURFACE 1
#else
#define WB_HAS_IOSURFACE 0
#endif

@implementation WbTextureShare

+ (BOOL)isTextureShareSupported {
#if WB_HAS_IOSURFACE
  // IOSurface 随 macOS 10.6+ 提供；10.14 起特性完整。
  // 后续 Wave：IOSurfaceCreate + FlutterTextureRegistry 注册，
  // 供 C++ 核心直接写入共享表面。
  return YES;
#else
  return NO;
#endif
}

@end
