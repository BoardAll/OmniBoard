// texture_share.cpp — GPU 共享纹理能力预留骨架（D3D11 / DXGI；不接
// 'whiteboard/windows' 通道，独立编译单元）。
//
// 目标：为屏幕捕获与批注合成提供零拷贝 GPU 路径——D3D11 纹理以共享句柄
// 交给 Flutter 外部纹理合成（替代 GDI BitBlt 的 CPU 拷贝）。
//
// 接入步骤（待后续 Wave 批准后在 CMakeLists.txt 追加链接 d3d11 / dxgi）：
//   1. D3D11CreateDevice 创建硬件设备（目标格式 B8G8R8A8_UNORM）；
//   2. ID3D11Device::CreateTexture2D 创建纹理，MiscFlags 含
//      D3D11_RESOURCE_MISC_SHARED（或 SHARED_NTHANDLE +
//      IDXGIResource1::CreateSharedHandle 取得 NT 句柄）；
//   3. FlutterDesktopTextureRegistrarRegisterExternalTexture 注册外部纹理
//      （像素格式 kFlutterDesktopPixelFormatBGRA8888）；
//   4. 捕获 / 合成线程写入纹理后调用
//      FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable。
//
// 本编译单元当前不引用任何 D3D/DXGI 运行符号（避免为骨架引入链接依赖），
// 仅提供接口与占位实现，保证能力边界可演进且不破坏现有构建。

#include "window_plugin.h"

#include <d3d11.h>
#include <dxgi.h>

#include <cstdint>
#include <memory>

namespace wb::platform::windows {

// 共享纹理描述（预留）。
struct SharedTextureDesc {
  int32_t width = 0;
  int32_t height = 0;
  // Flutter 外部纹理统一为 BGRA8888（DXGI_FORMAT_B8G8R8A8_UNORM）。
  DXGI_FORMAT format = DXGI_FORMAT_B8G8R8A8_UNORM;
};

// 共享纹理提供者接口（预留）：创建 / 释放可供 Flutter 合入场景的 GPU 纹理。
class SharedTextureProvider {
 public:
  virtual ~SharedTextureProvider() = default;

  // 当前环境（系统 / 驱动 / 会话）是否支持该能力。
  virtual bool IsSupported() const = 0;

  // 创建指定尺寸的共享纹理；成功返回 true。
  virtual bool Create(const SharedTextureDesc& desc) = 0;

  // 释放纹理与设备资源。
  virtual void Dispose() = 0;
};

namespace {

// 占位实现：当前构建不引入 d3d11 / dxgi 链接依赖，恒不支持。
// 接入时替换为基于 D3D11 设备的实现（见文件头注释的接入步骤）。
class UnavailableSharedTextureProvider final : public SharedTextureProvider {
 public:
  bool IsSupported() const override { return false; }
  bool Create(const SharedTextureDesc&) override { return false; }
  void Dispose() override {}
};

}  // namespace

// 创建共享纹理提供者（骨架：恒返回不支持占位实现）。
std::unique_ptr<SharedTextureProvider> CreateSharedTextureProvider() {
  return std::make_unique<UnavailableSharedTextureProvider>();
}

}  // namespace wb::platform::windows
