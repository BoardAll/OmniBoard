# Web 端方案设计（Flutter Web + WASM）

- 文档版本：v1.0
- 状态：详细设计稿
- 所属文档：《白板软件设计文档 v0.5》《C++ 核心引擎接口设计 v1.0》《Flutter + C++ 工程结构设计 v1.0》《渲染引擎设计 v1.0》
- 适用范围：Flutter Web + C++ WASM
- 定位：Web 端是白板的轻量入口，优先 Flutter Web + WASM；若性能不达标，后续独立实现 Web 渲染层

---

## 1. 设计目标

1. **一套代码**：与桌面端共用 Flutter UI 和 C++ 核心。
2. **WASM 复用**：C++ 核心编译为 WASM，Web 端复用同一套逻辑。
3. **性能可接受**：白板 60fps，1000 元素可用，3D 30fps。
4. **功能对齐**：除透明批注、鼠标穿透、全局快捷键、本地模型外，功能与桌面端一致。
5. **加载快**：WASM 分块加载，首屏 < 3s。
6. **内存可控**：WASM 内存上限可配，避免浏览器崩溃。
7. **可降级**：性能不足时降级渲染、降级 3D、降级缓存。
8. **可替换**：Flutter Web 不达标时，可独立实现 Web 渲染层，C++ 核心仍复用。
9. **跨浏览器**：Chrome / Edge / Safari / Firefox 主流版本。
10. **AI 与 MCP**：Web 端可调用云端 AI，可通过 MCP 暴露工具。

---

## 2. Web 端定位

### 2.1 能力范围

| 能力 | Web 端 | 说明 |
|---|---|---|
| 全功能编辑 | ✅ | 与桌面端一致 |
| 2D 渲染 | ✅ | CanvasKit |
| 3D 渲染 | ✅ | WebGL2 / WebGPU |
| 函数渲染 | ✅ | WASM |
| 2D 几何 | ✅ | WASM |
| 思维导图 | ✅ | WASM |
| 表格 | ✅ | WASM |
| 流程图 | ✅ | WASM |
| PDF 内嵌 | ✅ | PDFium WASM |
| AI 助手 | ✅ | 云端 |
| 语音 | ✅ | 浏览器 API |
| 实时协作 | ✅ | WebSocket |
| 离线编辑 | ✅ | IndexedDB |
| 页面管理 | ✅ | 与桌面端一致 |
| 主题与背景 | ✅ | 与桌面端一致 |
| 透明批注 | ❌ | 不支持 |
| 鼠标穿透 | ❌ | 不支持 |
| 全局快捷键 | ❌ | 不支持 |
| 本地模型 | ❌ | 不支持 |
| 系统托盘 | ❌ | 不支持 |
| 多窗口 | ⚠️ | 有限 |

### 2.2 浏览器支持

| 浏览器 | 最低版本 | 说明 |
|---|---|---|
| Chrome | 90+ | 推荐 |
| Edge | 90+ | 推荐 |
| Safari | 15+ | 部分限制 |
| Firefox | 90+ | 推荐 |
| Opera | 76+ | 可用 |
| 移动浏览器 | 最新 | 查看为主 |

### 2.3 设备支持

- 桌面浏览器：完整支持
- 平板浏览器：完整支持，触屏优化
- 手机浏览器：查看、评论、轻编辑

---

## 3. 整体架构

```text
┌──────────────────────────────────────────────────────────────┐
│ 浏览器                                                       │
├──────────────────────────────────────────────────────────────┤
│ Flutter Web UI                                               │
│ 工具栏 / 面板 / 圆盘 / AI / 页面管理                         │
├──────────────────────────────────────────────────────────────┤
│ Flutter Web 渲染层                                           │
│ CanvasKit / HTML Renderer / CustomPainter                    │
├──────────────────────────────────────────────────────────────┤
│ JS Interop 层                                                │
│ dart:js_interop / dart:ffi (WASM)                            │
├──────────────────────────────────────────────────────────────┤
│ C++ WASM 核心                                                │
│ 白板内核 / 命令 / CRDT / 渲染 / 3D / 函数 / 流程图           │
├──────────────────────────────────────────────────────────────┤
│ Web API 层                                                   │
│ WebGL2 / WebGPU / WebAudio / WebRTC / IndexedDB / WebSocket  │
├──────────────────────────────────────────────────────────────┤
│ 服务端                                                       │
│ AI Gateway / Open API / MCP Server / 同步服务                │
└──────────────────────────────────────────────────────────────┘
```

---

## 4. Flutter Web 渲染器

### 4.1 渲染器选择

| 渲染器 | 说明 | 推荐 |
|---|---|---|
| CanvasKit | Skia 编译为 WASM，性能好，一致性强 | ✅ 默认 |
| HTML Renderer | DOM 渲染，兼容性好，性能差 | 降级 |
| WebAssembly + Skia | Flutter 3.22+ 默认 | ✅ |

结论：

- 默认使用 **CanvasKit**
- 低端设备降级到 HTML Renderer
- 后续 Flutter 版本可能统一为 WASM + Skia

### 4.2 CanvasKit 配置

```dart
// main.dart
import 'dart:ui' as ui;

void main() {
  // CanvasKit 配置
  ui.PlatformDispatcher.instance.views.first
    .platformDispatcher
    .onBeginFrame = ...;
}
```

`web/index.html` 配置：

```html
<script>
  window.flutterConfiguration = {
    canvasKitBaseUrl: "/canvaskit/",
    canvasKitVariant: "full",
    renderer: "canvaskit",
  };
</script>
```

### 4.3 渲染分层

与桌面端一致：

```text
Background
  → Static
    → Dynamic
      → Render3D
        → Render2D
          → Function
            → Video
              → Annotation
                → Selection
                  → Cursor
                    → UI
```

Flutter Web 负责：

- Background：Canvas 2D
- Static：Canvas 2D
- Dynamic：Canvas 2D
- Selection：Canvas 2D
- Cursor：Canvas 2D
- UI：Flutter Widget

WASM 负责：

- Render3D：WebGL2 / WebGPU
- Render2D：路径生成
- Function：路径生成
- Document：PDFium 渲染

### 4.4 纹理共享

WASM 渲染到 OffscreenCanvas，Flutter 通过 `HtmlElementView` 或 `Texture` 显示。

```dart
// 创建 OffscreenCanvas
final canvas = html.OffscreenCanvas(width, height);
final ctx = canvas.getContext('webgl2');

// WASM 渲染到 canvas
wbRender3D(elementId, canvas);

// Flutter 显示
HtmlElementView(
  viewType: 'wb-3d-${elementId}',
)
```

或使用 `PlatformView`：

```dart
PlatformViewLink(
  viewType: 'wb-3d',
  surfaceFactory: (context, controller) {
    return AndroidViewSurface(controller: controller);
  },
  onCreatePlatformView: (params) {
    return PlatformViewsService.initSurfaceAndroidView(
      id: params.id,
      viewType: 'wb-3d',
      layoutDirection: TextDirection.ltr,
      creationParams: {'elementId': elementId},
      creationParamsCodec: StandardMessageCodec(),
    )..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
     ..create();
  },
)
```

---

## 5. C++ WASM 编译

### 5.1 Emscripten 配置

```bash
# 激活 Emscripten
source emsdk_env.sh

# 编译
emcmake cmake -B build/wasm -DWB_BUILD_WASM=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/wasm
```

### 5.2 CMake 配置

```cmake
if(WB_BUILD_WASM)
  set(CMAKE_EXECUTABLE_SUFFIX ".js")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fexceptions -s DISABLE_EXCEPTION_CATCHING=0")

  target_link_options(wb_core PUBLIC
    -s WASM=1
    -s MODULARIZE=1
    -s EXPORT_NAME=WbCore
    -s ALLOW_MEMORY_GROWTH=1
    -s INITIAL_MEMORY=64MB
    -s MAXIMUM_MEMORY=2GB
    -s STACK_SIZE=5MB
    -s EXPORTED_FUNCTIONS=@exports.json
    -s EXPORTED_RUNTIME_METHODS=['ccall','cwrap','UTF8ToString','stringToUTF8','lengthBytesUTF8','HEAPU8']
    -s ENVIRONMENT=web,worker
    -s FILESYSTEM=1
    -s FORCE_FILESYSTEM=1
    -s USE_PTHREADS=1
    -s PTHREAD_POOL_SIZE=4
    -s SHARED_MEMORY=1
    -s OFFSCREENCANVAS_SUPPORT=1
    -s OFFSCREEN_FRAMEBUFFER=1
    -s WEBGL2_BACKEND=1
    -s MIN_WEBGL_VERSION=2
    -s MAX_WEBGL_VERSION=2
    --no-entry
  )
endif()
```

### 5.3 导出函数

`exports.json`：

```json
[
  "_wb_init",
  "_wb_shutdown",
  "_wb_version",
  "_wb_create_board",
  "_wb_destroy_board",
  "_wb_execute_command",
  "_wb_execute_tool",
  "_wb_tool_list",
  "_wb_page_list",
  "_wb_page_create",
  "_wb_page_duplicate",
  "_wb_page_delete",
  "_wb_page_move",
  "_wb_element_create",
  "_wb_element_update",
  "_wb_element_delete",
  "_wb_element_list",
  "_wb_render_3d",
  "_wb_render_3d_pick_surface",
  "_wb_render_3d_set_face_color",
  "_wb_function_create",
  "_wb_function_set_style",
  "_wb_flowchart_create",
  "_wb_flowchart_auto_layout",
  "_wb_free"
]
```

### 5.4 多线程

- 使用 `-s USE_PTHREADS=1`
- 需要 SharedArrayBuffer
- 需要 COOP/COEP Header

服务端配置：

```http
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Nginx 示例：

```nginx
add_header Cross-Origin-Opener-Policy same-origin;
add_header Cross-Origin-Embedder-Policy require-corp;
```

### 5.5 内存管理

| 配置 | 值 |
|---|---|
| INITIAL_MEMORY | 64MB |
| MAXIMUM_MEMORY | 2GB |
| ALLOW_MEMORY_GROWTH | 1 |
| STACK_SIZE | 5MB |

内存策略：

- 大对象使用堆分配
- 及时释放
- 避免内存泄漏
- 监控内存使用

### 5.6 WASM 大小优化

| 优化 | 效果 |
|---|---|
| `-O3` | 最高优化 |
| `--closure 1` | 压缩 JS |
| `-s ASSERTIONS=0` | 关闭断言 |
| `-s MALLOC=emmalloc` | 小内存分配器 |
| 移除未使用模块 | 减小体积 |
| 分离调试符号 | 生产不包含 |
| Brotli 压缩 | 传输压缩 |

目标：WASM < 5MB（Brotli 后 < 2MB）

---

## 6. WASM 加载

### 6.1 加载流程

```text
1. 浏览器加载 index.html
2. Flutter 初始化
3. 加载 wb_core.js
4. 实例化 wb_core.wasm
5. 初始化 C++ 核心
6. 创建白板
7. 渲染首屏
```

### 6.2 加载器

```dart
import 'dart:js_interop';
import 'dart:async';

@JS('WbCore')
external JSPromise<JSObject> _wbCoreModule();

class WbCoreLoader {
  static JSObject? _module;
  static Completer<JSObject>? _completer;

  static Future<JSObject> load() async {
    if (_module != null) return _module!;
    if (_completer != null) return _completer!.future;

    _completer = Completer<JSObject>();
    try {
      final module = await _wbCoreModule().toDart;
      _module = module;
      _completer!.complete(module);
    } catch (e) {
      _completer!.completeError(e);
    }
    return _completer!.future;
  }
}
```

### 6.3 分块加载

```text
1. 首屏：加载核心 WASM（2D 白板）
2. 后台：加载 3D 模块
3. 后台：加载函数模块
4. 后台：加载 PDF 模块
5. 按需：加载流程图、表格、导图
```

### 6.4 进度显示

```dart
class WbCoreLoader {
  static Stream<double> get progress async* {
    yield 0.0;
    // 加载 JS
    yield 0.2;
    // 加载 WASM
    yield 0.6;
    // 初始化
    yield 0.9;
    // 完成
    yield 1.0;
  }
}
```

### 6.5 缓存

- WASM 文件使用 `Cache-Control: max-age=31536000, immutable`
- 版本号控制缓存失效
- Service Worker 缓存

---

## 7. JS Interop

### 7.1 dart:js_interop

```dart
import 'dart:js_interop';

@JS('wb')
external WbJs get wb;

@JS()
@staticInterop
class WbJs {}

extension WbJsExt on WbJs {
  external JSString executeCommand(JSString cmd);
  external JSString executeTool(JSString tool, JSString args);
  external JSString createBoard(JSString json);
  external void destroyBoard(int handle);
}
```

### 7.2 WASM 调用

```dart
import 'dart:js_interop';

class WbWasm {
  late final JSObject _module;
  late final JSFunction _ccall;

  Future<void> init() async {
    _module = await WbCoreLoader.load();
    _ccall = _module['ccall'] as JSFunction;
  }

  String executeCommand(String cmd) {
    final result = _ccall.callAsFunction(
      _module,
      'wb_execute_command'.toJS,
      cmd.toJS,
    );
    return (result as JSString).toDart;
  }

  void destroy() {
    _ccall.callAsFunction(_module, 'wb_shutdown'.toJS);
  }
}
```

### 7.3 二进制数据

```dart
import 'dart:typed_data';
import 'dart:js_interop';

Uint8List readWasmBuffer(int ptr, int size) {
  final heap = _module['HEAPU8'] as JSUint8Array;
  final view = heap.toDart.buffer.asUint8List(ptr, size);
  return Uint8List.fromList(view);
}
```

### 7.4 回调

```dart
@JS()
external void registerCallback(JSFunction callback);

void setupCallbacks() {
  registerCallback(((JSString event, JSString data) {
    _handleEvent(event.toDart, data.toDart);
  }).toJS);
}
```

---

## 8. 渲染

### 8.1 2D 渲染

- Flutter CanvasKit 渲染 2D 元素
- CustomPainter 绘制
- 静态层缓存为 `Picture`
- 动态层增量重绘

```dart
class WhiteboardPainter extends CustomPainter {
  final DisplayList displayList;

  @override
  void paint(Canvas canvas, Size size) {
    for (final item in displayList.items) {
      _paintItem(canvas, item);
    }
  }

  @override
  bool shouldRepaint(covariant WhiteboardPainter oldDelegate) {
    return oldDelegate.displayList != displayList;
  }
}
```

### 8.2 3D 渲染

- WASM 使用 WebGL2 渲染
- 渲染到 OffscreenCanvas
- Flutter 通过 `HtmlElementView` 显示

```dart
class Render3DView extends StatefulWidget {
  final String elementId;
  final int width;
  final int height;

  @override
  State<Render3DView> createState() => _Render3DViewState();
}

class _Render3DViewState extends State<Render3DView> {
  @override
  Widget build(BuildContext context) {
    return HtmlElementView(
      viewType: 'wb-3d-${widget.elementId}',
    );
  }
}
```

### 8.3 函数渲染

- WASM 计算采样点
- Flutter 绘制路径

```dart
class FunctionPainter extends CustomPainter {
  final List<Offset> points;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    for (int i = 0; i < points.length; i++) {
      if (i == 0) {
        path.moveTo(points[i].dx, points[i].dy);
      } else {
        path.lineTo(points[i].dx, points[i].dy);
      }
    }
    canvas.drawPath(path, Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke);
  }
}
```

### 8.4 PDF 渲染

- PDFium 编译为 WASM
- 渲染到 OffscreenCanvas
- Flutter 显示

### 8.5 视频渲染

- 原生 `<video>` 元素
- 通过 `HtmlElementView` 嵌入
- 不经过 WebGL 上传

---

## 9. 性能优化

### 9.1 目标

| 指标 | 目标 |
|---|---|
| 首屏加载 | < 3s |
| 白板帧率 | 60fps |
| 3D 帧率 | 30fps |
| 1000 元素操作 | 可用 |
| 内存占用 | < 1GB |
| WASM 大小 | < 5MB（未压缩） |
| 同步延迟 | < 100ms |

### 9.2 优化策略

| 策略 | 说明 |
|---|---|
| WASM 分块 | 按需加载模块 |
| 懒加载 | 3D、PDF 按需 |
| 缓存 | Service Worker |
| 压缩 | Brotli |
| 视口裁剪 | 只渲染可见 |
| 脏矩形 | 只重绘变化 |
| 对象池 | 减少 GC |
| 纹理缓存 | 静态内容 |
| 离屏 Canvas | 3D 渲染 |
| Web Worker | 重计算 |
| SharedArrayBuffer | 多线程 |
| CanvasKit | 高性能渲染 |

### 9.3 性能监控

```dart
class WebPerfMonitor {
  static void trackFrameRate() {
    // 使用 requestAnimationFrame 监控帧率
  }

  static void trackMemory() {
    // 使用 performance.memory
  }

  static void trackLoadTime() {
    // 使用 performance.timing
  }
}
```

### 9.4 降级策略

| 场景 | 降级 |
|---|---|
| 低端设备 | HTML Renderer |
| 3D 性能不足 | 降级为静态缩略图 |
| 内存不足 | 清理缓存 |
| WASM 加载失败 | 提示刷新 |
| SharedArrayBuffer 不可用 | 单线程模式 |

---

## 10. 离线支持

### 10.1 IndexedDB

- 存储白板数据
- 存储页面
- 存储元素
- 存储缩略图
- 存储主题

### 10.2 Service Worker

```javascript
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open('wb-v1').then((cache) => {
      return cache.addAll([
        '/',
        '/main.dart.js',
        '/wb_core.js',
        '/wb_core.wasm',
        '/canvaskit/canvaskit.wasm',
      ]);
    })
  );
});
```

### 10.3 离线编辑

- 本地 CRDT
- 联网后合并
- 冲突解决
- 同步队列

### 10.4 缓存策略

| 资源 | 策略 |
|---|---|
| HTML | 不缓存 |
| JS / WASM | 长期缓存，版本号 |
| 图片 | 长期缓存 |
| API | 不缓存 |
| 白板数据 | IndexedDB |

---

## 11. 实时协作

### 11.1 WebSocket

```dart
import 'dart:html';

class WebSocketSync {
  WebSocket? _socket;

  void connect(String url, String token) {
    _socket = WebSocket(url);
    _socket!.onOpen.listen((_) {
      _socket!.send(jsonEncode({'type': 'auth', 'token': token}));
    });
    _socket!.onMessage.listen((event) {
      _handleMessage(event.data);
    });
    _socket!.onClose.listen((_) {
      _reconnect();
    });
  }
}
```

### 11.2 WebRTC（预留）

- 音视频预留
- 后续接入 mediasoup
- Web 端使用浏览器 WebRTC API

### 11.3 光标同步

- 通过 WebSocket 发送光标位置
- 节流：50ms
- 批量发送

---

## 12. AI 与语音

### 12.1 AI 助手

- 云端 AI Gateway
- REST / WebSocket 调用
- 与桌面端一致

### 12.2 语音输入

浏览器 API：

```dart
import 'dart:js_interop';

@JS('webkitSpeechRecognition')
external JSFunction get speechRecognition;

class VoiceInput {
  void start() {
    final recognition = speechRecognition.callAsConstructor();
    recognition['continuous'] = true;
    recognition['interimResults'] = true;
    recognition['lang'] = 'zh-CN';
    recognition['onresult'] = ((JSObject event) {
      final results = event['results'];
      // 处理识别结果
    }).toJS;
    recognition.callMethod('start'.toJS);
  }
}
```

### 12.3 TTS

```dart
import 'dart:js_interop';

@JS('speechSynthesis')
external SpeechSynthesis get speechSynthesis;

class Tts {
  void speak(String text) {
    final utterance = SpeechSynthesisUtterance(text);
    utterance.lang = 'zh-CN';
    speechSynthesis.speak(utterance);
  }
}
```

### 12.4 兼容性

| 功能 | Chrome | Edge | Safari | Firefox |
|---|---|---|---|---|
| Web Speech API | ✅ | ✅ | ⚠️ | ⚠️ |
| MediaRecorder | ✅ | ✅ | ✅ | ✅ |
| WebAudio | ✅ | ✅ | ✅ | ✅ |

---

## 13. 主题与背景

- 与桌面端一致
- 主题 Token 从 C++ 核心获取
- 主题包通过 HTTP 加载
- 图片资源通过 HTTP 加载
- 缓存到 IndexedDB

---

## 14. 页面管理

- 与桌面端一致
- 缩略图通过 WASM 渲染
- 缩略图缓存到 IndexedDB

---

## 15. 圆盘与工具栏

- 与桌面端一致
- 圆盘使用 Flutter Widget
- 工具栏使用 Flutter Widget
- 上下文工具栏使用 Flutter Widget

---

## 16. 限制与降级

### 16.1 不支持的功能

| 功能 | 原因 | 替代 |
|---|---|---|
| 透明批注 | 浏览器限制 | 无 |
| 鼠标穿透 | 浏览器限制 | 无 |
| 全局快捷键 | 浏览器限制 | 页面内快捷键 |
| 本地模型 | 性能限制 | 云端 AI |
| 系统托盘 | 浏览器限制 | 无 |
| 多窗口 | 浏览器限制 | 标签页 |
| 屏幕捕获 | 需用户授权 | `getDisplayMedia` |

### 16.2 部分支持

| 功能 | 限制 |
|---|---|
| 文件系统 | 使用 File System Access API |
| 剪贴板 | 需用户授权 |
| 通知 | 需用户授权 |
| 语音 | 浏览器支持不一 |
| 3D | 依赖 WebGL2 |

### 16.3 降级方案

- 透明批注：Web 端隐藏入口
- 全局快捷键：改为页面内快捷键
- 本地模型：改为云端 AI
- 多窗口：改为标签页
- 屏幕捕获：使用 `getDisplayMedia`

---

## 17. 浏览器兼容

### 17.1 特性检测

```dart
class BrowserFeatures {
  static bool get hasWebGL2 {
    final canvas = html.CanvasElement();
    return canvas.getContext('webgl2') != null;
  }

  static bool get hasSharedArrayBuffer {
    return js.context.hasProperty('SharedArrayBuffer');
  }

  static bool get hasOffscreenCanvas {
    return js.context.hasProperty('OffscreenCanvas');
  }

  static bool get hasIndexedDB {
    return js.context.hasProperty('indexedDB');
  }

  static bool get hasServiceWorker {
    return js.context.hasProperty('serviceWorker');
  }

  static bool get hasWebRTC {
    return js.context.hasProperty('RTCPeerConnection');
  }
}
```

### 17.2 兼容矩阵

| 特性 | Chrome | Edge | Safari | Firefox |
|---|---|---|---|---|
| CanvasKit | ✅ | ✅ | ✅ | ✅ |
| WASM | ✅ | ✅ | ✅ | ✅ |
| WebGL2 | ✅ | ✅ | ✅ | ✅ |
| WebGPU | ✅ | ✅ | ⚠️ | ⚠️ |
| SharedArrayBuffer | ✅ | ✅ | ✅ | ✅ |
| OffscreenCanvas | ✅ | ✅ | ✅ | ✅ |
| IndexedDB | ✅ | ✅ | ✅ | ✅ |
| Service Worker | ✅ | ✅ | ✅ | ✅ |
| WebRTC | ✅ | ✅ | ✅ | ✅ |
| Web Speech | ✅ | ✅ | ⚠️ | ⚠️ |

### 17.3 Polyfill

- SharedArrayBuffer：需要 COOP/COEP
- WebGPU：降级到 WebGL2
- Web Speech：降级到云端 ASR

---

## 18. 安全

### 18.1 安全头

```http
Content-Security-Policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' https://api.whiteboard.example.com wss://api.whiteboard.example.com;
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
```

### 18.2 认证

- OAuth 2.0
- JWT
- Token 存储在内存，不存 localStorage
- Refresh Token 存 HttpOnly Cookie

### 18.3 数据

- 传输 HTTPS
- 存储加密
- 敏感数据脱敏

---

## 19. 构建与部署

### 19.1 构建

```bash
# 1. 构建 WASM（仓库封装：Windows 用 tools\scripts\build_wasm.ps1 -CopyToWebAssets，
#    等价于下述链路；preset 已内置 WB_BUILD_WASM=ON / Release）
source emsdk_env.sh
emcmake cmake --preset wasm
cmake --build --preset wasm-release

# 2. 复制 WASM（链接产物落在 build/wasm/bin/）
cp build/wasm/bin/wb_core.js apps/web/web/
cp build/wasm/bin/wb_core.wasm apps/web/web/

# 3. 构建 Flutter Web
cd apps/web
flutter build web --release
```

### 19.2 构建产物

```text
apps/web/build/web/
  index.html
  main.dart.js
  main.dart.wasm
  canvaskit/
    canvaskit.wasm
    canvaskit.js
  wb_core.js
  wb_core.wasm
  assets/
    AssetManifest.json
    FontManifest.json
    fonts/
    images/
  flutter_service_worker.js
  manifest.json
```

### 19.3 部署

- 静态托管：Netlify / Vercel / Cloudflare Pages
- CDN：CloudFront / Cloudflare
- 服务端：Nginx / Caddy
- 容器：Docker

### 19.4 Nginx 配置

```nginx
server {
  listen 443 ssl http2;
  server_name whiteboard.example.com;

  root /var/www/whiteboard;
  index index.html;

  # 安全头
  add_header Cross-Origin-Opener-Policy same-origin;
  add_header Cross-Origin-Embedder-Policy require-corp;
  add_header X-Content-Type-Options nosniff;

  # WASM
  location ~* \.wasm$ {
    types { application/wasm wasm; }
    add_header Cache-Control "public, max-age=31536000, immutable";
  }

  # JS / CSS
  location ~* \.(js|css)$ {
    add_header Cache-Control "public, max-age=31536000, immutable";
  }

  # HTML
  location = /index.html {
    add_header Cache-Control "no-cache";
  }

  # SPA 路由
  location / {
    try_files $uri $uri/ /index.html;
  }

  # API 代理
  location /api/ {
    proxy_pass https://api.whiteboard.example.com/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }

  # WebSocket 代理
  location /ws {
    proxy_pass https://api.whiteboard.example.com/ws;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
  }
}
```

### 19.5 Docker

```dockerfile
FROM nginx:alpine

COPY build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
```

---

## 20. 测试

### 20.1 单元测试

- Flutter 单元测试
- WASM 单元测试

### 20.2 集成测试

```dart
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('create element', (tester) async {
    await tester.pumpWidget(WhiteboardApp());
    await tester.tap(find.byKey(Key('sticky-tool')));
    await tester.pumpAndSettle();
    // ...
  });
}
```

### 20.3 浏览器测试

- Playwright
- Puppeteer
- Selenium

```javascript
const { chromium } = require('playwright');

test('create board', async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto('https://whiteboard.example.com');
  await page.click('[data-testid="create-board"]');
  await expect(page.locator('[data-testid="board-title"]')).toBeVisible();
});
```

### 20.4 性能测试

- Lighthouse
- WebPageTest
- Chrome DevTools Performance

---

## 21. 里程碑

### M9.1：Flutter Web 骨架
- Flutter Web 应用
- CanvasKit 配置
- 路由
- 基础 UI

### M9.2：WASM 集成
- C++ 编译 WASM
- JS Interop
- WASM 加载
- 内存管理

### M9.3：2D 渲染
- CustomPainter
- Display List
- 缓存

### M9.4：3D 渲染
- WebGL2
- OffscreenCanvas
- HtmlElementView

### M9.5：函数渲染
- WASM 采样
- Flutter 绘制

### M9.6：PDF 渲染
- PDFium WASM
- OffscreenCanvas

### M9.7：实时协作
- WebSocket
- 光标同步

### M9.8：AI 与语音
- 云端 AI
- Web Speech API

### M9.9：离线支持
- IndexedDB
- Service Worker

### M9.10：性能优化
- 分块加载
- 缓存
- 降级

### M9.11：兼容性
- 浏览器测试
- Polyfill

### M9.12：部署
- 构建脚本
- Nginx
- Docker

---

## 22. 最终确认清单

| 项 | 确认结果 |
|---|---|
| Web 端 | Flutter Web |
| 渲染器 | CanvasKit |
| C++ 核心 | WASM |
| 3D | WebGL2 |
| 函数 | WASM + Flutter |
| PDF | PDFium WASM |
| 实时协作 | WebSocket |
| 离线 | IndexedDB + Service Worker |
| AI | 云端 |
| 语音 | Web Speech API |
| 透明批注 | 不支持 |
| 鼠标穿透 | 不支持 |
| 全局快捷键 | 不支持 |
| 本地模型 | 不支持 |
| 多窗口 | 有限 |
| 浏览器 | Chrome / Edge / Safari / Firefox |
| 降级 | 支持 |
| WASM 大小 | < 5MB |
| 首屏 | < 3s |
| 白板帧率 | 60fps |
| 3D 帧率 | 30fps |

---

## 23. 附录：Web API 使用清单

| API | 用途 |
|---|---|
| WebGL2 | 3D 渲染 |
| WebGPU | 3D 渲染（可选） |
| OffscreenCanvas | 离屏渲染 |
| Canvas 2D | 2D 渲染 |
| WebSocket | 实时协作 |
| WebRTC | 音视频（预留） |
| WebAudio | 音频 |
| MediaRecorder | 录制 |
| IndexedDB | 离线存储 |
| Service Worker | 缓存 |
| Web Speech | 语音识别 |
| SpeechSynthesis | 语音合成 |
| File System Access | 文件访问 |
| Clipboard | 剪贴板 |
| Notification | 通知 |
| getDisplayMedia | 屏幕捕获 |
| requestAnimationFrame | 帧循环 |
| SharedArrayBuffer | 多线程 |
| Web Worker | 后台计算 |

---

## 24. 附录：WASM 编译选项

| 选项 | 值 | 说明 |
|---|---|---|
| WASM | 1 | 启用 WASM |
| MODULARIZE | 1 | 模块化 |
| EXPORT_NAME | WbCore | 导出名 |
| ALLOW_MEMORY_GROWTH | 1 | 内存增长 |
| INITIAL_MEMORY | 64MB | 初始内存 |
| MAXIMUM_MEMORY | 2GB | 最大内存 |
| STACK_SIZE | 5MB | 栈大小 |
| USE_PTHREADS | 1 | 多线程 |
| PTHREAD_POOL_SIZE | 4 | 线程池 |
| SHARED_MEMORY | 1 | 共享内存 |
| OFFSCREENCANVAS_SUPPORT | 1 | 离屏 Canvas |
| OFFSCREEN_FRAMEBUFFER | 1 | 离屏帧缓冲 |
| WEBGL2_BACKEND | 1 | WebGL2 |
| MIN_WEBGL_VERSION | 2 | 最低 WebGL2 |
| MAX_WEBGL_VERSION | 2 | 最高 WebGL2 |
| ENVIRONMENT | web,worker | 环境 |
| FILESYSTEM | 1 | 文件系统 |
| FORCE_FILESYSTEM | 1 | 强制文件系统 |
| ASSERTIONS | 0 | 关闭断言 |
| MALLOC | emmalloc | 内存分配器 |
| -O3 | — | 最高优化 |
| --closure | 1 | 压缩 JS |

---

以上是《Web 端方案设计（Flutter Web + WASM）v1.0》完整内容。