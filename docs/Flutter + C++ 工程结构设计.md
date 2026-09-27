# Flutter + C++ 工程结构设计

- 文档版本：v1.0
- 状态：详细设计稿
- 所属文档：《白板软件设计文档 v0.5》《C++ 核心引擎接口设计 v1.0》《渲染引擎设计 v1.0》
- 适用范围：Flutter UI + C++ 核心 + 平台插件
- 定位：定义 Flutter 与 C++ 的工程结构、目录划分、构建流程、FFI 集成、依赖管理、多平台打包

---

## 1. 设计目标

1. **一套代码多端**：Windows / macOS / Linux / Web / iOS / Android 一套代码。
2. **UI 与内核分离**：Flutter 负责 UI，C++ 负责内核。
3. **FFI 稳定**：C ABI 稳定，跨语言零拷贝。
4. **Monorepo**：所有代码在一个仓库，统一版本管理。
5. **构建一致**：CMake + Flutter Build 统一构建流程。
6. **依赖清晰**：第三方依赖统一管理，版本锁定。
7. **可测试**：C++ 单元测试 + Flutter 单元测试 + 集成测试。
8. **可发布**：多平台打包、签名、发布自动化。
9. **可扩展**：插件化、模块化。
10. **AI 友好**：便于 AI 辅助开发。

---

## 2. Monorepo 结构

```text
whiteboard/
  README.md
  LICENSE
  VERSION
  .gitignore
  .gitattributes
  .editorconfig
  .clang-format
  .clang-tidy
  .dart-format
  CMakeLists.txt
  CMakePresets.json
  pubspec.yaml
  melos.yaml
  analysis_options.yaml

  apps/
    desktop/              Flutter 桌面应用
    web/                  Flutter Web 应用
    mobile/               Flutter 移动应用（后续）

  packages/
    ui/                   Flutter UI 组件
    ui_kit/               Flutter 基础组件库
    theme/                Flutter 主题系统
    icons/                图标包
    fonts/                字体资源
    core_dart/            Dart 核心（FFI 封装）
    ai_dart/              Dart AI SDK
    api_client/           Dart Open API SDK
    mcp_client/           Dart MCP 客户端

  core/                   C++ 核心引擎
    include/wb/           公共头文件
    src/                  实现
    third_party/          第三方依赖
    tests/                单元测试
    benchmarks/           性能测试
    CMakeLists.txt

  platform/               平台插件
    windows/              Windows 插件
    macos/                macOS 插件
    linux/                Linux 插件
    web/                  Web 插件
    ios/                  iOS 插件
    android/              Android 插件

  services/               服务端
    api/                  REST / WebSocket
    ai_gateway/           AI Gateway
    mcp_server/           MCP Server
    convert/              文档转换
    sfu/                  音视频（预留）

  tools/                  开发工具
    scripts/              构建脚本
    codegen/              代码生成
    l10n/                 本地化
    migration/            数据迁移

  docs/                   文档
    design/               设计文档
    api/                  API 文档
    guides/               开发指南

  tests/                  集成测试
    e2e/                  端到端测试
    perf/                 性能测试
    fixture/              测试数据

  assets/                 静态资源
    images/
    themes/
    templates/
    sounds/

  build/                  构建输出（.gitignore）
  dist/                   发布产物（.gitignore）
```

---

## 3. 应用层（apps）

### 3.1 desktop

```text
apps/desktop/
  lib/
    main.dart
    app.dart
    routes.dart
    pages/
      board_list_page.dart
      board_edit_page.dart
      settings_page.dart
    widgets/
      radial_toolbar.dart
      sidebar.dart
      ai_panel.dart
      page_manager.dart
      canvas_view.dart
      floating_toolbar.dart
    services/
      ffi_service.dart
      ai_service.dart
      sync_service.dart
      theme_service.dart
      shortcut_service.dart
    state/
      board_state.dart
      page_state.dart
      selection_state.dart
      ai_state.dart
      theme_state.dart
    platform/
      platform_service.dart
      window_service.dart
      transparent_overlay_service.dart
  windows/
  macos/
  linux/
  pubspec.yaml
```

### 3.2 web

```text
apps/web/
  lib/
    main.dart
    app.dart
    wasm/
      wb_core_loader.dart
      wb_core_bindings.dart
    pages/
    widgets/
    services/
    state/
  web/
    index.html
    manifest.json
  pubspec.yaml
```

### 3.3 mobile（后续）

```text
apps/mobile/
  lib/
  ios/
  android/
  pubspec.yaml
```

---

## 4. Flutter 包（packages）

### 4.1 ui

Flutter UI 组件库。

```text
packages/ui/
  lib/
    components/
      button.dart
      icon_button.dart
      card.dart
      panel.dart
      toolbar.dart
      radial_toolbar.dart
      color_picker.dart
      font_picker.dart
      layer_panel.dart
      page_thumbnail.dart
      ai_message.dart
      ai_action_card.dart
      context_menu.dart
      dialog.dart
      toast.dart
      tooltip.dart
    layouts/
      sidebar_layout.dart
      panel_layout.dart
      split_layout.dart
    painters/
      canvas_painter.dart
      grid_painter.dart
      selection_painter.dart
      cursor_painter.dart
      radial_painter.dart
    gestures/
      pan_gesture.dart
      zoom_gesture.dart
      drag_gesture.dart
      long_press_gesture.dart
    animations/
      fade.dart
      slide.dart
      scale.dart
      spring.dart
  pubspec.yaml
```

### 4.2 ui_kit

基础组件库（无业务逻辑）。

```text
packages/ui_kit/
  lib/
    foundation/
      colors.dart
      typography.dart
      spacing.dart
      radius.dart
      elevation.dart
      duration.dart
    widgets/
      icon.dart
      text.dart
      image.dart
      divider.dart
      badge.dart
      avatar.dart
      progress.dart
      skeleton.dart
    utils/
      color_utils.dart
      text_utils.dart
      layout_utils.dart
  pubspec.yaml
```

### 4.3 theme

主题系统。

```text
packages/theme/
  lib/
    theme.dart
    theme_data.dart
    theme_tokens.dart
    theme_loader.dart
    theme_manager.dart
    theme_pack.dart
    builtin/
      clean_professional.dart
      dark_night.dart
      blackboard.dart
      greenboard.dart
      minimal.dart
      hand_drawn.dart
      cyberpunk.dart
      kids.dart
      enterprise.dart
  pubspec.yaml
```

### 4.4 icons

图标包。

```text
packages/icons/
  lib/
    icons.dart
    linear/
    filled/
    hand_drawn/
    minimal/
    pixel/
  assets/
    svg/
  pubspec.yaml
```

### 4.5 core_dart

Dart FFI 封装。

```text
packages/core_dart/
  lib/
    wb_core.dart
    wb_core_bindings.dart
    wb_core_ffi.dart
    wb_core_wasm.dart
    models/
      board.dart
      page.dart
      element.dart
      connector.dart
      layer.dart
      tool.dart
      theme.dart
      background.dart
    services/
      board_service.dart
      page_service.dart
      element_service.dart
      tool_service.dart
      theme_service.dart
      background_service.dart
      render_service.dart
      ai_service.dart
    utils/
      json_codec.dart
      binary_codec.dart
      handle_manager.dart
  src/                    FFI 原生库加载器
  pubspec.yaml
```

### 4.6 ai_dart

AI SDK。

```text
packages/ai_dart/
  lib/
    ai_client.dart
    ai_session.dart
    ai_message.dart
    ai_tool_call.dart
    ai_audio.dart
    ai_context.dart
    providers/
      openai_provider.dart
      anthropic_provider.dart
      custom_provider.dart
  pubspec.yaml
```

### 4.7 api_client

Open API SDK。

```text
packages/api_client/
  lib/
    api_client.dart
    auth.dart
    boards_api.dart
    pages_api.dart
    elements_api.dart
    connectors_api.dart
    comments_api.dart
    exports_api.dart
    history_api.dart
    ai_api.dart
    mcp_api.dart
    models/
    errors.dart
    pagination.dart
  pubspec.yaml
```

### 4.8 mcp_client

MCP 客户端。

```text
packages/mcp_client/
  lib/
    mcp_client.dart
    mcp_transport.dart
    mcp_stdio_transport.dart
    mcp_sse_transport.dart
    mcp_http_transport.dart
    mcp_protocol.dart
    mcp_tools.dart
    mcp_resources.dart
    mcp_prompts.dart
  pubspec.yaml
```

---

## 5. C++ 核心（core）

### 5.1 目录结构

```text
core/
  CMakeLists.txt
  include/
    wb/
      wb.h                  总入口
      base/
      ffi/
      facade/
      command/
      tool/
      model/
      page/
      element/
      mindmap/
      table/
      flowchart/
      function/
      render3d/
      render2d/
      document/
      annotation/
      render/
      theme/
      background/
      geometry/
      layout/
      crdt/
      sync/
      permission/
      serialization/
      platform/
  src/
    base/
    ffi/
    facade/
    command/
    tool/
    model/
    page/
    element/
    mindmap/
    table/
    flowchart/
    function/
    render3d/
    render2d/
    document/
    annotation/
    render/
    theme/
    background/
    geometry/
    layout/
    crdt/
    sync/
    permission/
    serialization/
    platform/
  third_party/
    bgfx/
    glfw/
    glm/
    pdfium/
    json/
    fmt/
    spdlog/
    catch2/
    benchmark/
  tests/
    unit/
    integration/
    perf/
  benchmarks/
  tools/
    codegen/
    schema/
```

### 5.2 第三方依赖

| 库 | 用途 | 许可 |
|---|---|---|
| bgfx | 3D 渲染 | BSD-2 |
| glm | 数学库 | MIT |
| PDFium | PDF 渲染 | BSD-3 |
| nlohmann/json | JSON | MIT |
| fmt | 格式化 | MIT |
| spdlog | 日志 | MIT |
| Catch2 | 单元测试 | BSL-1.0 |
| Google Benchmark | 性能测试 | Apache-2.0 |
| Skia | 2D 渲染（可选） | BSD-3 |
| Emscripten | WASM | MIT |
| Yjs C++ 绑定 | CRDT（可选） | MIT |

### 5.3 CMake 顶层

```cmake
cmake_minimum_required(VERSION 3.20)
project(wb VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(WB_BUILD_SHARED "Build shared library" ON)
option(WB_BUILD_STATIC "Build static library" OFF)
option(WB_BUILD_TESTS "Build tests" ON)
option(WB_BUILD_BENCHMARKS "Build benchmarks" OFF)
option(WB_BUILD_WASM "Build for WebAssembly" OFF)
option(WB_BUILD_3D "Build 3D renderer" ON)
option(WB_BUILD_PDF "Build PDF support" ON)

add_subdirectory(third_party)
add_subdirectory(src)
if(WB_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
if(WB_BUILD_BENCHMARKS)
  add_subdirectory(benchmarks)
endif()
```

### 5.4 CMake Presets

```json
{
  "version": 6,
  "configurePresets": [
    {
      "name": "windows-x64",
      "generator": "Visual Studio 17 2022",
      "architecture": "x64",
      "binaryDir": "${sourceDir}/build/windows-x64",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Release"
      }
    },
    {
      "name": "macos-arm64",
      "generator": "Xcode",
      "binaryDir": "${sourceDir}/build/macos-arm64",
      "cacheVariables": {
        "CMAKE_OSX_ARCHITECTURES": "arm64",
        "CMAKE_BUILD_TYPE": "Release"
      }
    },
    {
      "name": "linux-x64",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/linux-x64",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Release"
      }
    },
    {
      "name": "wasm",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/wasm",
      "cacheVariables": {
        "CMAKE_TOOLCHAIN_FILE": "$env{EMSDK}/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake",
        "WB_BUILD_WASM": "ON",
        "CMAKE_BUILD_TYPE": "Release"
      }
    }
  ]
}
```

### 5.5 核心库构建

```cmake
add_library(wb_core
  src/base/log.cpp
  src/base/memory.cpp
  src/ffi/ffi_api.cpp
  src/ffi/ffi_handle.cpp
  src/command/command_bus.cpp
  src/command/transaction.cpp
  src/command/history.cpp
  src/tool/tool_registry.cpp
  # ...
)

target_include_directories(wb_core
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)

target_link_libraries(wb_core
  PRIVATE
    wb::bgfx
    wb::glm
    wb::json
    wb::fmt
    wb::spdlog
)

if(WB_BUILD_PDF)
  target_link_libraries(wb_core PRIVATE wb::pdfium)
endif()

if(WB_BUILD_WASM)
  target_link_options(wb_core PUBLIC
    -s WASM=1
    -s MODULARIZE=1
    -s EXPORT_NAME=WbCore
    -s ALLOW_MEMORY_GROWTH=1
    -s EXPORTED_RUNTIME_METHODS=['ccall','cwrap','UTF8ToString']
    --no-entry
  )
endif()
```

---

## 6. 平台插件（platform）

### 6.1 Windows

```text
platform/windows/
  CMakeLists.txt
  src/
    window_plugin.cpp
    transparent_overlay.cpp
    shortcut_plugin.cpp
    tray_plugin.cpp
    screen_capture.cpp
    texture_share.cpp
  include/
    window_plugin.h
  pubspec.yaml
```

### 6.2 macOS

```text
platform/macos/
  CMakeLists.txt
  src/
    window_plugin.mm
    transparent_overlay.mm
    shortcut_plugin.mm
    tray_plugin.mm
    screen_capture.mm
    texture_share.mm
  include/
    window_plugin.h
  pubspec.yaml
```

### 6.3 Linux

```text
platform/linux/
  CMakeLists.txt
  src/
    window_plugin.cpp
    transparent_overlay_x11.cpp
    transparent_overlay_wayland.cpp
    shortcut_plugin.cpp
    tray_plugin.cpp
    screen_capture.cpp
  include/
    window_plugin.h
  pubspec.yaml
```

### 6.4 Web

```text
platform/web/
  lib/
    wb_core_loader.dart
    wb_core_bindings.dart
    web_window.dart
  web/
    wb_core.wasm
    wb_core.js
  pubspec.yaml
```

### 6.5 插件接口

每个平台插件实现统一 Dart 接口：

```dart
abstract class WindowPlugin {
  Future<void> setTransparent(bool transparent);
  Future<void> setAlwaysOnTop(bool onTop);
  Future<void> setIgnoreMouseEvents(bool ignore, {bool forward = false});
  Future<void> setFullscreen(bool fullscreen);
  Future<void> setPosition(int x, int y);
  Future<void> setSize(int width, int height);
}

abstract class ShortcutPlugin {
  Future<void> register(String accelerator, String id);
  Future<void> unregister(String id);
  Future<void> unregisterAll();
  Stream<String> get onTriggered;
}

abstract class TrayPlugin {
  Future<void> setIcon(String iconPath);
  Future<void> setTooltip(String tooltip);
  Future<void> setMenu(List<TrayMenuItem> items);
}
```

---

## 7. 服务端（services）

```text
services/
  api/
    src/
      app.ts
      routes/
        boards.ts
        pages.ts
        elements.ts
        connectors.ts
        comments.ts
        exports.ts
        history.ts
        ai.ts
        mcp.ts
      middleware/
        auth.ts
        rateLimit.ts
        audit.ts
        idempotency.ts
      services/
        boardService.ts
        pageService.ts
        elementService.ts
      db/
        schema.ts
        migrations/
    package.json
    tsconfig.json

  ai_gateway/
    src/
      app.py
      providers/
        openai.py
        anthropic.py
        custom.py
      tools/
        registry.py
        executor.py
      asr/
        whisper.py
      tts/
        azure.py
      session/
        manager.py
    requirements.txt

  mcp_server/
    src/
      server.ts
      protocol/
        jsonrpc.ts
        initialize.ts
      tools/
        registry.ts
        executor.ts
      resources/
        registry.ts
      prompts/
        registry.ts
      auth/
        apiKey.ts
        oauth.ts
      transport/
        stdio.ts
        sse.ts
        http.ts
    package.json

  convert/
    src/
      pdf_converter.py
    Dockerfile
```

---

## 8. 依赖管理

### 8.1 Flutter 依赖

`apps/desktop/pubspec.yaml`：

```yaml
name: whiteboard_desktop
description: Whiteboard Desktop App
publish_to: none
version: 1.0.0+1

environment:
  sdk: '>=3.3.0 <4.0.0'
  flutter: '>=3.19.0'

dependencies:
  flutter:
    sdk: flutter
  whiteboard_ui:
    path: ../../packages/ui
  whiteboard_ui_kit:
    path: ../../packages/ui_kit
  whiteboard_theme:
    path: ../../packages/theme
  whiteboard_icons:
    path: ../../packages/icons
  whiteboard_core:
    path: ../../packages/core_dart
  whiteboard_ai:
    path: ../../packages/ai_dart
  whiteboard_api_client:
    path: ../../packages/api_client
  whiteboard_mcp_client:
    path: ../../packages/mcp_client
  provider: ^6.1.0
  riverpod: ^2.5.0
  go_router: ^14.0.0
  window_manager: ^0.4.0
  hotkey_manager: ^0.2.0
  tray_manager: ^0.3.0
  screen_retriever: ^0.1.0
  flutter_webrtc: ^0.10.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
  integration_test:
    sdk: flutter

flutter:
  uses-material-design: true
  assets:
    - assets/images/
    - assets/templates/
  fonts:
    - family: Inter
      fonts:
        - asset: assets/fonts/Inter-Regular.ttf
        - asset: assets/fonts/Inter-Medium.ttf
          weight: 500
        - asset: assets/fonts/Inter-SemiBold.ttf
          weight: 600
```

### 8.2 Melos 配置

`melos.yaml`：

```yaml
name: whiteboard
repository: https://github.com/example/whiteboard

packages:
  - apps/**
  - packages/**
  - platform/**

scripts:
  analyze:
    run: melos exec -- flutter analyze
    description: 分析所有 Flutter 包

  format:
    run: melos exec -- dart format --set-exit-if-changed .
    description: 格式化所有 Dart 代码

  test:
    run: melos exec -- flutter test
    description: 运行所有测试

  build:desktop:
    run: melos exec --scope=whiteboard_desktop -- flutter build

  bootstrap:
    run: melos bootstrap
```

### 8.3 C++ 依赖

`core/third_party/CMakeLists.txt`：

```cmake
include(FetchContent)

FetchContent_Declare(
  bgfx
  GIT_REPOSITORY https://github.com/bkaradzic/bgfx.cmake.git
  GIT_TAG v1.126.8466-416
)
FetchContent_MakeAvailable(bgfx)

FetchContent_Declare(
  glm
  GIT_REPOSITORY https://github.com/g-truc/glm.git
  GIT_TAG 1.0.1
)
FetchContent_MakeAvailable(glm)

FetchContent_Declare(
  json
  GIT_REPOSITORY https://github.com/nlohmann/json.git
  GIT_TAG v3.11.3
)
FetchContent_MakeAvailable(json)

FetchContent_Declare(
  fmt
  GIT_REPOSITORY https://github.com/fmtlib/fmt.git
  GIT_TAG 10.2.1
)
FetchContent_MakeAvailable(fmt)

FetchContent_Declare(
  spdlog
  GIT_REPOSITORY https://github.com/gabime/spdlog.git
  GIT_TAG v1.14.1
)
FetchContent_MakeAvailable(spdlog)
```

---

## 9. FFI 集成

### 9.1 桌面端加载

`packages/core_dart/lib/wb_core_ffi.dart`：

```dart
import 'dart:ffi';
import 'dart:io';

class WbCoreFFI {
  static DynamicLibrary? _lib;

  static DynamicLibrary load() {
    if (_lib != null) return _lib!;

    if (Platform.isWindows) {
      _lib = DynamicLibrary.open('wb_core.dll');
    } else if (Platform.isMacOS) {
      _lib = DynamicLibrary.open('libwb_core.dylib');
    } else if (Platform.isLinux) {
      _lib = DynamicLibrary.open('libwb_core.so');
    } else if (Platform.isIOS) {
      _lib = DynamicLibrary.process();
    } else if (Platform.isAndroid) {
      _lib = DynamicLibrary.open('libwb_core.so');
    } else {
      throw UnsupportedError('Unsupported platform');
    }
    return _lib!;
  }
}
```

### 9.2 Web 端加载

`packages/core_dart/lib/wb_core_wasm.dart`：

```dart
import 'dart:js_interop';

@JS('WbCore')
external WbCoreModule get wbCore;

@JS()
@staticInterop
class WbCoreModule {
  external factory WbCoreModule();
}

extension WbCoreModuleExt on WbCoreModule {
  external JSFunction get ccall;
  external JSFunction get cwrap;
}

class WbCoreWasm {
  static WbCoreModule? _module;

  static Future<WbCoreModule> load() async {
    if (_module != null) return _module!;
    _module = WbCoreModule();
    return _module!;
  }
}
```

### 9.3 绑定生成

使用 `ffigen` 生成 Dart FFI 绑定：

```yaml
# packages/core_dart/ffigen.yaml
name: WbCoreBindings
description: FFI bindings for wb_core
output: 'lib/wb_core_bindings.dart'
headers:
  entry-points:
    - '../../core/include/wb/wb.h'
  include-directives:
    - '../../core/include/wb/**'
functions:
  include:
    - 'wb_.*'
structs:
  include:
    - 'WB.*'
```

生成：

```bash
dart run ffigen --config ffigen.yaml
```

### 9.4 句柄管理

```dart
class WbHandle {
  final int id;
  const WbHandle(this.id);
  static const WbHandle invalid = WbHandle(0);
  bool get isValid => id != 0;
}

class WbHandleManager {
  static final Map<int, Object> _objects = {};
  static int _nextId = 1;

  static WbHandle register(Object obj) {
    final id = _nextId++;
    _objects[id] = obj;
    return WbHandle(id);
  }

  static T? get<T>(WbHandle handle) {
    return _objects[handle.id] as T?;
  }

  static void unregister(WbHandle handle) {
    _objects.remove(handle.id);
  }
}
```

### 9.5 JSON 协议封装

```dart
class WbJsonCodec {
  static String encode(Map<String, dynamic> data) {
    return jsonEncode(data);
  }

  static Map<String, dynamic> decode(String json) {
    return jsonDecode(json) as Map<String, dynamic>;
  }

  static T decodeAs<T>(String json, T Function(Map<String, dynamic>) fromJson) {
    return fromJson(decode(json));
  }
}
```

### 9.6 二进制协议

```dart
class WbBinaryCodec {
  static Uint8List encodeHeader({
    required int magic,
    required int version,
    required int type,
    required int size,
    required int flags,
  }) {
    final bytes = BytesBuilder();
    bytes.add(_uint32(magic));
    bytes.add(_uint16(version));
    bytes.add(_uint16(type));
    bytes.add(_uint32(size));
    bytes.add(_uint32(flags));
    return bytes.toBytes();
  }

  static Uint8List _uint32(int value) {
    final data = ByteData(4);
    data.setUint32(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  static Uint8List _uint16(int value) {
    final data = ByteData(2);
    data.setUint16(0, value, Endian.little);
    return data.buffer.asUint8List();
  }
}
```

### 9.7 内存管理

```dart
class WbMemory {
  static String freeAndCopy(Pointer<Utf8> ptr) {
    final str = ptr.toDartString();
    wbFree(ptr);
    return str;
  }
}
```

---

## 10. 构建流程

### 10.1 桌面端构建

```bash
# 1. 构建 C++ 核心
cmake --preset windows-x64
cmake --build build/windows-x64 --config Release

# 2. 复制动态库到 Flutter 项目
cp build/windows-x64/Release/wb_core.dll apps/desktop/windows/runner/

# 3. 构建 Flutter 应用
cd apps/desktop
flutter build windows --release
```

### 10.2 Web 构建

```bash
# 1. 激活 Emscripten
source emsdk_env.sh

# 2. 构建 WASM
cmake --preset wasm
cmake --build build/wasm

# 3. 复制 WASM 到 Web 项目
cp build/wasm/wb_core.js apps/web/web/
cp build/wasm/wb_core.wasm apps/web/web/

# 4. 构建 Flutter Web
cd apps/web
flutter build web --release --wasm
```

### 10.3 一键构建脚本

`tools/scripts/build_all.sh`：

```bash
#!/bin/bash
set -e

PLATFORM=${1:-all}

build_windows() {
  echo "Building Windows..."
  cmake --preset windows-x64
  cmake --build build/windows-x64 --config Release
  cp build/windows-x64/Release/wb_core.dll apps/desktop/windows/runner/
  cd apps/desktop && flutter build windows --release
}

build_macos() {
  echo "Building macOS..."
  cmake --preset macos-arm64
  cmake --build build/macos-arm64
  cp build/macos-arm64/libwb_core.dylib apps/desktop/macos/Frameworks/
  cd apps/desktop && flutter build macos --release
}

build_linux() {
  echo "Building Linux..."
  cmake --preset linux-x64
  cmake --build build/linux-x64
  cp build/linux-x64/libwb_core.so apps/desktop/linux/lib/
  cd apps/desktop && flutter build linux --release
}

build_web() {
  echo "Building Web..."
  source $EMSDK/emsdk_env.sh
  cmake --preset wasm
  cmake --build build/wasm
  cp build/wasm/wb_core.js apps/web/web/
  cp build/wasm/wb_core.wasm apps/web/web/
  cd apps/web && flutter build web --release --wasm
}

case $PLATFORM in
  windows) build_windows ;;
  macos) build_macos ;;
  linux) build_linux ;;
  web) build_web ;;
  all)
    build_windows
    build_macos
    build_linux
    build_web
    ;;
  *)
    echo "Unknown platform: $PLATFORM"
    exit 1
    ;;
esac
```

### 10.4 构建产物

```text
dist/
  windows/
    whiteboard.exe
    wb_core.dll
    data/
  macos/
    Whiteboard.app/
  linux/
    whiteboard
    libwb_core.so
    data/
  web/
    index.html
    main.dart.js
    wb_core.wasm
    wb_core.js
    assets/
```

---

## 11. 代码生成

### 11.1 FFI 绑定

```bash
dart run ffigen --config packages/core_dart/ffigen.yaml
```

### 11.2 JSON 模型

使用 `json_serializable` 生成：

```dart
@JsonSerializable()
class Board {
  final String id;
  final String name;
  final String? description;

  Board({required this.id, required this.name, this.description});

  factory Board.fromJson(Map<String, dynamic> json) => _$BoardFromJson(json);
  Map<String, dynamic> toJson() => _$BoardToJson(this);
}
```

生成：

```bash
dart run build_runner build --delete-conflicting-outputs
```

### 11.3 本地化

```bash
flutter gen-l10n
```

`l10n.yaml`：

```yaml
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
```

### 11.4 主题代码生成

从主题 JSON 生成 Dart 代码：

```bash
dart run tools/codegen/theme_codegen.dart
```

### 11.5 工具代码生成

从 ToolRegistry 生成 Dart 和 TypeScript 客户端：

```bash
dart run tools/codegen/tool_codegen.dart
```

---

## 12. 测试

### 12.1 C++ 单元测试

```text
core/tests/unit/
  test_command_bus.cpp
  test_history.cpp
  test_tool_registry.cpp
  test_page_manager.cpp
  test_element_manager.cpp
  test_flowchart_layout.cpp
  test_function_parser.cpp
  test_crdt_merge.cpp
```

```cpp
TEST_CASE("CommandBus executes command", "[command]") {
  CommandBus bus;
  auto cmd = std::make_shared<CreateElementCommand>();
  bus.registerCommand(cmd);

  ToolContext ctx;
  auto result = bus.execute("element.create", ctx);
  REQUIRE(result.ok());
}
```

### 12.2 Flutter 单元测试

```text
apps/desktop/test/
  unit/
    board_state_test.dart
    page_state_test.dart
    selection_state_test.dart
  widget/
    radial_toolbar_test.dart
    sidebar_test.dart
```

### 12.3 集成测试

```text
tests/e2e/
  create_board_test.dart
  create_element_test.dart
  ai_flow_test.dart
  page_management_test.dart
```

### 12.4 性能测试

```text
core/benchmarks/
  benchmark_render.cpp
  benchmark_layout.cpp
  benchmark_crdt.cpp
  benchmark_function.cpp
```

### 12.5 测试命令

```bash
# C++ 测试
cd core && ctest --test-dir build/linux-x64

# Flutter 测试
melos run test

# 集成测试
flutter test integration_test/

# 性能测试
cd core && ./build/linux-x64/benchmarks/wb_benchmarks
```

---

## 13. 代码规范

### 13.1 C++ 规范

- 使用 C++20
- 命名空间：`wb::`
- 类名：`PascalCase`
- 方法：`camelCase`
- 成员变量：`snake_case_`
- 常量：`kPascalCase`
- 头文件保护：`#pragma once`
- 使用 `std::unique_ptr` 和 `std::shared_ptr`
- 禁止裸指针
- 异常安全
- 使用 `Result<T>` 而非异常

### 13.2 Dart 规范

- 使用 `flutter_lints`
- 类名：`PascalCase`
- 方法：`camelCase`
- 变量：`camelCase`
- 常量：`camelCase`
- 文件：`snake_case.dart`
- 使用 `final` 和 `const`
- 避免 `dynamic`
- 使用 null safety

### 13.3 格式化

```bash
# C++
clang-format -i core/src/**/*.cpp core/include/**/*.h

# Dart
dart format apps packages
```

### 13.4 静态检查

```bash
# C++
clang-tidy core/src/**/*.cpp

# Dart
flutter analyze
```

---

## 14. CI/CD

### 14.1 GitHub Actions

`.github/workflows/build.yml`：

```yaml
name: Build

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.19.0'
      - name: Build C++ core
        run: |
          cmake --preset windows-x64
          cmake --build build/windows-x64 --config Release
      - name: Build Flutter
        run: |
          cd apps/desktop
          flutter build windows --release

  build-macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.19.0'
      - name: Build C++ core
        run: |
          cmake --preset macos-arm64
          cmake --build build/macos-arm64
      - name: Build Flutter
        run: |
          cd apps/desktop
          flutter build macos --release

  build-linux:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.19.0'
      - name: Install dependencies
        run: sudo apt-get install -y ninja-build libgtk-3-dev
      - name: Build C++ core
        run: |
          cmake --preset linux-x64
          cmake --build build/linux-x64
      - name: Build Flutter
        run: |
          cd apps/desktop
          flutter build linux --release

  build-web:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.19.0'
      - uses: mymindstorm/setup-emsdk@v14
      - name: Build WASM
        run: |
          cmake --preset wasm
          cmake --build build/wasm
      - name: Build Flutter Web
        run: |
          cd apps/web
          flutter build web --release --wasm

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
      - name: Run C++ tests
        run: |
          cmake --preset linux-x64
          cmake --build build/linux-x64
          ctest --test-dir build/linux-x64
      - name: Run Flutter tests
        run: |
          melos bootstrap
          melos run test
```

### 14.2 发布流程

```text
1. 更新 VERSION
2. 更新 CHANGELOG
3. 打 tag
4. CI 自动构建
5. 上传到 GitHub Releases
6. 更新官网下载链接
```

---

## 15. 开发环境

### 15.1 必需工具

| 工具 | 版本 | 用途 |
|---|---|---|
| Flutter | 3.19+ | UI 开发 |
| Dart | 3.3+ | Dart 开发 |
| CMake | 3.20+ | C++ 构建 |
| Ninja | 1.11+ | C++ 构建 |
| Clang | 16+ | C++ 编译 |
| MSVC | 2022 | Windows 编译 |
| Xcode | 15+ | macOS 编译 |
| Emscripten | 3.1.50+ | WASM 编译 |
| Melos | 6.0+ | Monorepo 管理 |
| Git | 2.40+ | 版本控制 |

### 15.2 推荐工具

| 工具 | 用途 |
|---|---|
| VS Code | 主编辑器 |
| CLion | C++ 开发 |
| Android Studio | Flutter 开发 |
| RenderDoc | 图形调试 |
| Tracy | 性能分析 |
| Perfetto | 性能分析 |

### 15.3 VS Code 配置

`.vscode/settings.json`：

```json
{
  "dart.flutterSdkPath": "/path/to/flutter",
  "dart.lineLength": 100,
  "editor.formatOnSave": true,
  "editor.rulers": [100],
  "files.associations": {
    "*.h": "cpp",
    "*.cpp": "cpp"
  },
  "C_Cpp.default.cppStandard": "c++20",
  "cmake.configureOnOpen": false
}
```

### 15.4 初始化脚本

`tools/scripts/setup.sh`：

```bash
#!/bin/bash
set -e

echo "Setting up development environment..."

# 安装 Melos
dart pub global activate melos

# 初始化 Monorepo
melos bootstrap

# 初始化 C++ 依赖
cd core
cmake --preset linux-x64
cd ..

# 安装 Flutter 依赖
cd apps/desktop
flutter pub get
cd ../..

echo "Setup complete!"
```

---

## 16. 版本管理

### 16.1 版本号

- 遵循 SemVer
- `VERSION` 文件统一管理
- Flutter 应用版本同步
- C++ 库版本同步

### 16.2 分支策略

```text
main          主分支，稳定版本
develop       开发分支
feature/*     功能分支
bugfix/*      修复分支
release/*     发布分支
hotfix/*      紧急修复
```

### 16.3 Commit 规范

```text
feat: 新功能
fix: 修复
docs: 文档
style: 格式
refactor: 重构
perf: 性能
test: 测试
chore: 杂项
```

---

## 17. 里程碑

### M0.1：Monorepo 初始化
- 目录结构
- Melos 配置
- CMake 配置
- CI 配置

### M0.2：C++ 核心构建
- 基础库
- FFI 层
- 单元测试

### M0.3：Flutter 应用骨架
- 桌面应用
- Web 应用
- UI 组件库

### M0.4：FFI 集成
- 桌面端加载
- Web WASM 加载
- 绑定生成
- 句柄管理

### M0.5：平台插件
- Windows
- macOS
- Linux
- Web

### M0.6：构建流程
- 一键构建脚本
- 多平台打包
- 代码生成

### M0.7：测试
- C++ 单元测试
- Flutter 单元测试
- 集成测试
- 性能测试

### M0.8：CI/CD
- GitHub Actions
- 自动构建
- 自动发布

---

## 18. 最终确认清单

| 项 | 确认结果 |
|---|---|
| Monorepo | 支持 |
| Flutter 应用 | desktop / web / mobile |
| Flutter 包 | ui / theme / icons / core_dart / ai_dart / api_client / mcp_client |
| C++ 核心 | core/ |
| 平台插件 | platform/ |
| 服务端 | services/ |
| 依赖管理 | Melos + CMake FetchContent |
| FFI 集成 | dart:ffi + ffigen |
| Web 集成 | WASM + dart:js_interop |
| 代码生成 | ffigen + json_serializable + 自定义 |
| 构建 | CMake + Flutter Build |
| 测试 | C++ + Flutter + 集成 + 性能 |
| CI/CD | GitHub Actions |
| 版本管理 | SemVer |
| 代码规范 | C++20 + Dart + clang-format + flutter_lints |

---

## 19. 附录：目录速查

| 目录 | 说明 |
|---|---|
| `apps/desktop` | Flutter 桌面应用 |
| `apps/web` | Flutter Web 应用 |
| `apps/mobile` | Flutter 移动应用 |
| `packages/ui` | UI 组件库 |
| `packages/ui_kit` | 基础组件库 |
| `packages/theme` | 主题系统 |
| `packages/icons` | 图标包 |
| `packages/core_dart` | Dart FFI 封装 |
| `packages/ai_dart` | Dart AI SDK |
| `packages/api_client` | Dart Open API SDK |
| `packages/mcp_client` | Dart MCP 客户端 |
| `core/` | C++ 核心引擎 |
| `platform/` | 平台插件 |
| `services/` | 服务端 |
| `tools/` | 开发工具 |
| `docs/` | 文档 |
| `tests/` | 集成测试 |
| `assets/` | 静态资源 |
| `build/` | 构建输出 |
| `dist/` | 发布产物 |

---

## 20. 附录：常用命令

```bash
# 初始化
melos bootstrap
dart run build_runner build

# C++ 构建
cmake --preset linux-x64
cmake --build build/linux-x64

# Flutter 构建
cd apps/desktop && flutter build linux --release

# Web 构建
cd apps/web && flutter build web --release --wasm

# 测试
ctest --test-dir build/linux-x64
melos run test

# 格式化
clang-format -i core/src/**/*.cpp
dart format apps packages

# 静态检查
clang-tidy core/src/**/*.cpp
flutter analyze

# 生成 FFI 绑定
dart run ffigen --config packages/core_dart/ffigen.yaml

# 生成 JSON 模型
dart run build_runner build --delete-conflicting-outputs

# 一键构建
./tools/scripts/build_all.sh
```

---

以上是《Flutter + C++ 工程结构设计 v1.0》完整内容。