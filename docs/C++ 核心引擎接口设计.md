# C++ 核心引擎接口设计

- 文档版本：v1.0
- 状态：详细设计稿
- 所属文档：《白板软件设计文档 v0.5》《齿轮圆盘交互详细设计 v1.1》《左侧栏与页面管理设计 v1.0》《可扩展工具栏设计 v1.0》《流程图模块设计 v1.0》
- 适用范围：Flutter UI + C++ 核心 + 云端 AI + MCP
- 定位：C++ 核心引擎是白板的唯一数据源和命令执行层，Flutter、AI、Open API、MCP 都通过它操作白板

---

## 1. 设计目标

1. **唯一数据源**：所有白板状态由 C++ 核心管理。
2. **唯一命令层**：所有操作走 Command Bus，AI 与用户一致。
3. **跨平台**：Windows / macOS / Linux / Web (WASM) 一套代码。
4. **跨语言**：Flutter 通过 dart:ffi 调用，C ABI 稳定。
5. **高性能**：零拷贝、对象池、增量更新、脏矩形。
6. **可扩展**：模块化、插件化、ToolRegistry 驱动。
7. **可审计**：所有命令可记录、可回放、可撤销。
8. **可测试**：核心逻辑不依赖 UI，可单元测试。
9. **可离线**：本地状态 + CRDT，联网后合并。
10. **AI 友好**：所有能力暴露为 Tool，支持 MCP。

---

## 2. 整体架构

```text
┌──────────────────────────────────────────────────────────────┐
│ Flutter UI / AI / Open API / MCP / 第三方 SDK                │
├──────────────────────────────────────────────────────────────┤
│ C ABI（FFI 导出层）                                          │
│  稳定接口 / JSON 或二进制协议 / 句柄管理                     │
├──────────────────────────────────────────────────────────────┤
│ Facade 层                                                    │
│  BoardFacade / PageFacade / ElementFacade / RenderFacade     │
├──────────────────────────────────────────────────────────────┤
│ Command Bus                                                  │
│  命令注册 / 事务 / 撤销 / 重做 / 审计 / 权限                 │
├──────────────────────────────────────────────────────────────┤
│ Tool Registry                                                │
│  工具定义 / 参数 Schema / 确认级别 / AI 调用                 │
├──────────────────────────────────────────────────────────────┤
│ 核心模块                                                     │
│  model / page / element / connector / frame / layer          │
│  mindmap / table / flowchart / function / render3d / render2d│
│  document / annotation / theme / background                  │
├──────────────────────────────────────────────────────────────┤
│ 支撑模块                                                     │
│  geometry / layout / crdt / sync / permission / audit        │
│  serialization / memory / thread / log                       │
├──────────────────────────────────────────────────────────────┤
│ 平台与 GPU 层                                                │
│  bgfx / Diligent / PDFium / 平台插件                         │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. 目录结构

```text
core/
  base/
    types.h                 基础类型
    rect.h                  矩形
    point.h                 点
    color.h                 颜色
    transform.h             变换
    error.h                 错误码
    log.h                   日志
    memory.h                内存池
    object_pool.h           对象池
    string_utils.h          字符串工具

  ffi/
    ffi_api.h               C ABI 导出
    ffi_api.cpp
    ffi_handle.h            句柄管理
    ffi_json.h              JSON 序列化
    ffi_binary.h            二进制协议

  facade/
    board_facade.h          白板门面
    page_facade.h           页面门面
    element_facade.h        元素门面
    render_facade.h         渲染门面
    ai_facade.h             AI 门面

  command/
    command.h               命令接口
    command_bus.h           命令总线
    command_registry.h      命令注册
    transaction.h           事务
    history.h               历史栈
    undo_redo.h             撤销重做

  tool/
    tool_registry.h         工具注册表
    tool_definition.h       工具定义
    tool_context.h          工具上下文
    tool_result.h           工具结果

  model/
    board.h                 白板
    page.h                  页面
    element.h               元素基类
    element_factory.h       元素工厂
    connector.h             连线
    frame.h                 画框
    layer.h                 图层
    group.h                 分组

  page/
    page_manager.h          页面管理
    page_thumbnail.h        缩略图
    page_operations.h       页面操作
    page_collaboration.h    页面协作

  element/
    element_manager.h       元素管理
    element_operations.h    元素操作
    element_style.h         元素样式
    element_hit_test.h      命中测试

  mindmap/
    mindmap_model.h         思维导图模型
    mindmap_layout.h        布局引擎
    mindmap_operations.h    操作

  table/
    table_model.h           表格模型
    table_formula.h         公式引擎
    table_operations.h      操作

  flowchart/
    flowchart_model.h       流程图模型
    flowchart_layout.h      自动布局
    flowchart_router.h      连线路由
    flowchart_swimlane.h    泳道
    flowchart_templates.h   模板
    flowchart_operations.h  操作

  function/
    expression.h            表达式
    parser.h                解析器
    compiler.h              编译器
    sampler.h               采样
    analyzer.h              分析
    function_render.h       函数渲染

  render3d/
    scene.h                 3D 场景
    mesh.h                  网格
    material.h              材质
    light.h                 光照
    camera.h                相机
    renderer.h              渲染器
    picker.h                拾取

  render2d/
    shape2d.h               2D 图形
    curve2d.h               2D 曲线
    annotation2d.h          2D 标注
    renderer2d.h            2D 渲染器

  document/
    document_model.h        文档模型
    pdf_renderer.h          PDF 渲染
    document_operations.h   文档操作

  annotation/
    annotation_layer.h      批注层
    transparent_mode.h      透明模式
    annotation_operations.h 批注操作

  render/
    display_list.h          显示列表
    render_layer.h          渲染层
    dirty_rect.h            脏矩形
    render_cache.h          渲染缓存
    render_scheduler.h      渲染调度

  theme/
    theme.h                 主题
    theme_loader.h          主题加载
    theme_tokens.h          主题 Token

  background/
    background.h            背景
    background_presets.h    背景预设
    background_renderer.h   背景渲染

  geometry/
    geometry.h              几何
    hit_test.h              命中测试
    transform.h             变换
    boolean_op.h            布尔运算

  layout/
    layout_engine.h         布局引擎
    alignment.h             对齐
    distribution.h          分布
    snap.h                  吸附

  crdt/
    crdt_doc.h              CRDT 文档
    crdt_element.h          CRDT 元素
    crdt_merge.h            合并

  sync/
    sync_manager.h          同步管理
    sync_transport.h        传输抽象
    av_provider.h           音视频预留
    interactive_provider.h  互动白板预留

  permission/
    permission.h            权限
    acl.h                   访问控制
    audit.h                 审计

  serialization/
    serializer.h            序列化
    deserializer.h          反序列化
    json_codec.h            JSON 编解码
    binary_codec.h          二进制编解码

  platform/
    platform.h              平台抽象
    window.h                窗口
    input.h                 输入
    clipboard.h             剪贴板
    file_system.h           文件系统
```

---

## 4. 基础类型

### 4.1 基础类型

```cpp
namespace wb {

using Handle = uint64_t;
using ElementId = std::string;
using PageId = std::string;
using BoardId = std::string;
using UserId = std::string;
using ToolId = std::string;
using Timestamp = int64_t;

struct Point {
  float x = 0;
  float y = 0;
};

struct Size {
  float width = 0;
  float height = 0;
};

struct Rect {
  float x = 0;
  float y = 0;
  float width = 0;
  float height = 0;
};

struct Color {
  uint8_t r = 0;
  uint8_t g = 0;
  uint8_t b = 0;
  uint8_t a = 255;
};

struct Transform {
  float m[6] = {1, 0, 0, 1, 0, 0};
};

}
```

### 4.2 错误码

```cpp
namespace wb {

enum class ErrorCode {
  Ok = 0,
  InvalidArgument,
  NotFound,
  PermissionDenied,
  Conflict,
  InternalError,
  NotSupported,
  Timeout,
  Cancelled,
  ResourceExhausted,
};

struct Error {
  ErrorCode code = ErrorCode::Ok;
  std::string message;
  std::string detail;
};

template <typename T>
struct Result {
  T value;
  Error error;
  bool ok() const { return error.code == ErrorCode::Ok; }
};

}
```

### 4.3 日志

```cpp
namespace wb {

enum class LogLevel { Trace, Debug, Info, Warn, Error, Fatal };

class Logger {
public:
  static Logger& instance();
  void setLevel(LogLevel level);
  void log(LogLevel level, const std::string& tag, const std::string& msg);

  void trace(const std::string& tag, const std::string& msg);
  void debug(const std::string& tag, const std::string& msg);
  void info(const std::string& tag, const std::string& msg);
  void warn(const std::string& tag, const std::string& msg);
  void error(const std::string& tag, const std::string& msg);
};

}
```

---

## 5. FFI 层

### 5.1 C ABI 导出

```cpp
extern "C" {

// 生命周期
WB_API int wb_init(const char* configJson);
WB_API void wb_shutdown();
WB_API const char* wb_version();

// 句柄
WB_API wb::Handle wb_create_board(const char* json);
WB_API void wb_destroy_board(wb::Handle h);
WB_API const char* wb_board_get(wb::Handle h);

// 命令
WB_API const char* wb_execute_command(wb::Handle h, const char* cmdJson);
WB_API const char* wb_execute_tool(const char* toolId, const char* argsJson);

// 渲染
WB_API const char* wb_get_display_list(wb::Handle h, int layer);
WB_API const char* wb_render_3d(wb::Handle h, const char* elementId, int w, int h2);
WB_API const char* wb_render_thumbnail(const char* pageId, int w, int h);

// 工具
WB_API const char* wb_tool_list();
WB_API const char* wb_tool_get(const char* toolId);

// 页面
WB_API const char* wb_page_list(const char* boardId);
WB_API const char* wb_page_create(const char* boardId, const char* json);
WB_API const char* wb_page_duplicate(const char* pageId);
WB_API const char* wb_page_delete(const char* pageId);
WB_API const char* wb_page_move(const char* pageId, int newIndex);
WB_API const char* wb_page_rename(const char* pageId, const char* name);
WB_API const char* wb_page_set_background(const char* pageId, const char* bgJson);

// 元素
WB_API const char* wb_element_create(const char* pageId, const char* json);
WB_API const char* wb_element_update(const char* elementId, const char* json);
WB_API const char* wb_element_delete(const char* elementId);
WB_API const char* wb_element_list(const char* pageId);

// 工具栏
WB_API const char* wb_toolbar_context(const char* elementIdsJson);
WB_API const char* wb_toolbar_invoke(const char* toolId, const char* argsJson);

// 圆盘
WB_API const char* wb_radial_layout(float cx, float cy, float size);
WB_API const char* wb_radial_hit_test(const char* layoutJson, float x, float y);
WB_API const char* wb_radial_state_create();
WB_API const char* wb_radial_state_get(const char* stateId);

// 3D
WB_API const char* wb_3d_create(const char* pageId, const char* json);
WB_API const char* wb_3d_pick_surface(const char* elementId, float x, float y);
WB_API const char* wb_3d_set_face_color(const char* elementId, int faceId, const char* color);
WB_API const char* wb_3d_set_material(const char* elementId, const char* matJson);
WB_API const char* wb_3d_transform(const char* elementId, const char* transformJson);

// 函数
WB_API const char* wb_function_create(const char* pageId, const char* json);
WB_API const char* wb_function_set_style(const char* elementId, const char* styleJson);
WB_API const char* wb_function_add(const char* elementId, const char* expr);
WB_API const char* wb_function_analyze(const char* elementId, const char* type);

// 流程图
WB_API const char* wb_flowchart_create(const char* pageId, const char* json);
WB_API const char* wb_flowchart_auto_layout(const char* flowchartId, const char* optionsJson);
WB_API const char* wb_flowchart_to_swimlane(const char* flowchartId, int orientation);
WB_API const char* wb_flowchart_label_branches(const char* flowchartId);

// 左侧栏
WB_API const char* wb_sidebar_toggle(const char* stateId);
WB_API const char* wb_sidebar_set_width(const char* stateId, int width);

// 主题
WB_API const char* wb_theme_load(const char* themeJson);
WB_API const char* wb_theme_current();
WB_API const char* wb_theme_list();

// 内存
WB_API void wb_free(const char* ptr);

}
```

### 5.2 句柄管理

```cpp
namespace wb {

class HandleManager {
public:
  Handle createHandle(void* ptr);
  void destroyHandle(Handle h);
  void* getPtr(Handle h);

  template <typename T>
  T* get(Handle h) { return static_cast<T*>(getPtr(h)); }

private:
  std::atomic<uint64_t> nextHandle_{1};
  std::unordered_map<Handle, void*> handles_;
  std::mutex mutex_;
};

}
```

### 5.3 JSON 协议

所有 FFI 接口输入输出使用 JSON，便于调试和跨语言。

```json
{
  "id": "cmd_123",
  "tool": "element.create",
  "args": {
    "pageId": "page_1",
    "elements": [
      {
        "type": "sticky",
        "text": "用户痛点",
        "position": { "x": 100, "y": 200 },
        "size": { "width": 200, "height": 150 },
        "style": { "color": "#FFE58F" }
      }
    ]
  },
  "dryRun": false,
  "transactionId": "txn_456"
}
```

返回：

```json
{
  "id": "cmd_123",
  "ok": true,
  "result": {
    "elementIds": ["elem_1"]
  },
  "error": null
}
```

### 5.4 二进制协议

高频接口使用二进制协议：

- 显示列表
- 3D 渲染结果
- 缩略图
- 大量元素更新

格式：

```text
[header 16 bytes]
  magic: uint32
  version: uint16
  type: uint16
  size: uint32
  flags: uint32

[payload]
  ...
```

---

## 6. 命令层

### 6.1 命令接口

```cpp
namespace wb {

class Command {
public:
  virtual ~Command() = default;

  virtual std::string id() const = 0;
  virtual std::string name() const = 0;

  virtual Result<void> validate(const ToolContext& ctx) = 0;
  virtual Result<ToolResult> execute(const ToolContext& ctx) = 0;
  virtual Result<void> undo(const ToolContext& ctx) = 0;
  virtual Result<void> redo(const ToolContext& ctx) = 0;

  virtual bool undoable() const { return true; }
  virtual ConfirmationLevel confirmation() const { return ConfirmationLevel::Auto; }
  virtual std::string scope() const { return ""; }
};

}
```

### 6.2 命令总线

```cpp
namespace wb {

class CommandBus {
public:
  void registerCommand(std::shared_ptr<Command> cmd);
  void unregisterCommand(const std::string& id);

  Result<ToolResult> execute(
    const std::string& commandId,
    const ToolContext& ctx
  );

  Result<ToolResult> executeBatch(
    const std::vector<std::string>& commandIds,
    const ToolContext& ctx
  );

  void beginTransaction(const std::string& txnId);
  void commitTransaction(const std::string& txnId);
  void rollbackTransaction(const std::string& txnId);

  Result<void> undo();
  Result<void> redo();

  void clearHistory();

private:
  std::unordered_map<std::string, std::shared_ptr<Command>> commands_;
  std::vector<std::string> history_;
  int historyIndex_ = -1;
  std::string currentTxn_;
  std::mutex mutex_;
};

}
```

### 6.3 事务

```cpp
namespace wb {

class Transaction {
public:
  explicit Transaction(const std::string& id);
  ~Transaction();

  void addCommand(const std::string& commandId, const ToolContext& ctx);
  void commit();
  void rollback();

  bool isActive() const;
  const std::string& id() const;

private:
  std::string id_;
  bool active_ = false;
  std::vector<std::pair<std::string, ToolContext>> commands_;
};

}
```

### 6.4 历史栈

```cpp
namespace wb {

struct HistoryEntry {
  std::string commandId;
  std::string txnId;
  ToolContext context;
  Timestamp timestamp;
  UserId userId;
  std::string toolId;
};

class History {
public:
  void push(const HistoryEntry& entry);
  bool canUndo() const;
  bool canRedo() const;
  HistoryEntry undo();
  HistoryEntry redo();
  void clear();

  std::vector<HistoryEntry> list(int limit = 100) const;

private:
  std::vector<HistoryEntry> entries_;
  int index_ = -1;
};

}
```

---

## 7. Tool Registry

### 7.1 工具定义

```cpp
namespace wb {

enum class ConfirmationLevel {
  Auto,
  Preview,
  Confirm,
};

struct ToolDefinition {
  std::string id;
  std::string name;
  std::string description;
  std::string icon;
  std::string group;
  std::vector<std::string> shortcuts;
  std::string scope;
  ConfirmationLevel confirmation = ConfirmationLevel::Auto;
  bool undoable = true;
  std::string paramsSchema;
  std::string returnsSchema;
  std::function<Result<ToolResult>(const ToolContext&)> execute;
};

}
```

### 7.2 工具注册表

```cpp
namespace wb {

class ToolRegistry {
public:
  static ToolRegistry& instance();

  void registerTool(const ToolDefinition& tool);
  void unregisterTool(const std::string& id);

  const ToolDefinition* getTool(const std::string& id) const;
  std::vector<ToolDefinition> listTools() const;
  std::vector<ToolDefinition> listToolsByGroup(const std::string& group) const;

  Result<ToolResult> execute(const std::string& id, const ToolContext& ctx);

  std::string toJson() const;

private:
  std::unordered_map<std::string, ToolDefinition> tools_;
  std::mutex mutex_;
};

}
```

### 7.3 工具上下文

```cpp
namespace wb {

struct ToolContext {
  BoardId boardId;
  PageId pageId;
  UserId userId;
  std::vector<ElementId> selection;
  std::string argsJson;
  std::string transactionId;
  bool dryRun = false;
  bool fromAI = false;
  Timestamp timestamp;
};

}
```

### 7.4 工具结果

```cpp
namespace wb {

struct ToolResult {
  std::string resultJson;
  std::vector<ElementId> affectedElements;
  std::vector<PageId> affectedPages;
  std::string undoToken;
  std::string message;
};

}
```

---

## 8. 核心模型

### 8.1 白板

```cpp
namespace wb {

struct Board {
  BoardId id;
  std::string name;
  std::string description;
  std::vector<PageId> pageIds;
  PageId currentPageId;
  std::string themeId;
  std::string backgroundId;
  UserId ownerId;
  std::vector<UserId> collaborators;
  Timestamp createdAt;
  Timestamp updatedAt;
  std::string metadataJson;
};

}
```

### 8.2 页面

```cpp
namespace wb {

struct Viewport {
  float x = 0;
  float y = 0;
  float zoom = 1.0f;
};

struct Page {
  PageId id;
  BoardId boardId;
  std::string name;
  int index = 0;
  std::string thumbnail;
  Background background;
  Viewport viewport;
  std::vector<ElementId> elementIds;
  Timestamp createdAt;
  Timestamp updatedAt;
  bool locked = false;
  bool hidden = false;
  std::vector<UserId> collaborators;
};

}
```

### 8.3 元素

```cpp
namespace wb {

enum class ElementType {
  Sticky,
  Text,
  Shape,
  Drawing,
  Connector,
  Image,
  Frame,
  MindMap,
  Table,
  Flowchart,
  Function,
  Render3D,
  Render2D,
  Document,
  Annotation,
  Group,
};

struct Element {
  ElementId id;
  PageId pageId;
  ElementType type;
  std::string name;
  Rect bounds;
  Transform transform;
  float rotation = 0;
  float opacity = 1.0f;
  int zIndex = 0;
  bool locked = false;
  bool hidden = false;
  std::string styleJson;
  std::string dataJson;
  std::string groupId;
  Timestamp createdAt;
  Timestamp updatedAt;
  UserId createdBy;
  UserId updatedBy;
};

}
```

### 8.4 连线

```cpp
namespace wb {

enum class ConnectorStyle { Straight, Orthogonal, Curved };
enum class ArrowStyle { None, Solid, Hollow, Open };

struct Connector {
  ElementId id;
  ElementId fromElementId;
  ElementId toElementId;
  std::string fromAnchor;
  std::string toAnchor;
  ConnectorStyle style = ConnectorStyle::Orthogonal;
  ArrowStyle arrowStart = ArrowStyle::None;
  ArrowStyle arrowEnd = ArrowStyle::Solid;
  std::string label;
  std::vector<Point> waypoints;
  bool autoRoute = true;
};

}
```

### 8.5 图层

```cpp
namespace wb {

struct Layer {
  std::string id;
  std::string name;
  ElementType type;
  std::string icon;
  bool visible = true;
  bool locked = false;
  int index = 0;
  std::string groupId;
};

}
```

---

## 9. 页面管理

### 9.1 页面管理器

```cpp
namespace wb {

class PageManager {
public:
  PageId createPage(const BoardId& boardId, const std::string& name);
  PageId duplicatePage(const PageId& pageId);
  void deletePage(const PageId& pageId);
  void movePage(const PageId& pageId, int newIndex);
  void renamePage(const PageId& pageId, const std::string& name);
  void lockPage(const PageId& pageId, bool locked);
  void hidePage(const PageId& pageId, bool hidden);
  void setBackground(const PageId& pageId, const Background& bg);

  std::vector<Page> listPages(const BoardId& boardId);
  Page getPage(const PageId& pageId);

  std::string renderThumbnail(const PageId& pageId, int width, int height);

  void splitPage(const PageId& pageId, const std::string& optionsJson);
  void mergePages(const std::vector<PageId>& pageIds);

private:
  std::unordered_map<PageId, Page> pages_;
  std::mutex mutex_;
};

}
```

### 9.2 缩略图

```cpp
namespace wb {

class PageThumbnail {
public:
  std::string render(const Page& page, int width, int height);
  void invalidate(const PageId& pageId);
  void invalidateAll();

private:
  std::unordered_map<PageId, std::string> cache_;
  std::mutex mutex_;
};

}
```

---

## 10. 元素管理

### 10.1 元素管理器

```cpp
namespace wb {

class ElementManager {
public:
  ElementId createElement(const PageId& pageId, const Element& element);
  void updateElement(const ElementId& id, const Element& element);
  void deleteElement(const ElementId& id);
  Element getElement(const ElementId& id);
  std::vector<Element> listElements(const PageId& pageId);

  void batchCreate(const PageId& pageId, const std::vector<Element>& elements);
  void batchUpdate(const std::vector<Element>& elements);
  void batchDelete(const std::vector<ElementId>& ids);

  void setZIndex(const ElementId& id, int zIndex);
  void bringForward(const ElementId& id);
  void sendBackward(const ElementId& id);
  void bringToFront(const ElementId& id);
  void sendToBack(const ElementId& id);

  void groupElements(const std::vector<ElementId>& ids);
  void ungroupElements(const std::string& groupId);

private:
  std::unordered_map<ElementId, Element> elements_;
  std::mutex mutex_;
};

}
```

### 10.2 元素操作

```cpp
namespace wb {

class ElementOperations {
public:
  void move(const std::vector<ElementId>& ids, Point delta);
  void resize(const ElementId& id, Rect newBounds);
  void rotate(const ElementId& id, float angle);
  void align(const std::vector<ElementId>& ids, Alignment alignment);
  void distribute(const std::vector<ElementId>& ids, Orientation orientation);
  void snap(const std::vector<ElementId>& ids, const SnapOptions& options);
};

}
```

---

## 11. 渲染层

### 11.1 显示列表

```cpp
namespace wb {

enum class RenderLayer {
  Background = 0,
  Static = 1,
  Dynamic = 2,
  Render3D = 3,
  Render2D = 4,
  Function = 5,
  Video = 6,
  Annotation = 7,
  Selection = 8,
  Cursor = 9,
  UI = 10,
};

struct DisplayItem {
  ElementId id;
  ElementType type;
  Rect bounds;
  std::string dataJson;
  int zIndex;
  bool selected;
  bool highlighted;
};

struct DisplayList {
  RenderLayer layer;
  std::vector<DisplayItem> items;
  Rect dirtyRect;
  bool fullRedraw;
};

class DisplayListBuilder {
public:
  DisplayList build(const Page& page, RenderLayer layer);
  DisplayList buildDirty(const Page& page, RenderLayer layer, const Rect& dirty);
};

}
```

### 11.2 渲染调度

```cpp
namespace wb {

class RenderScheduler {
public:
  void scheduleRender(const PageId& pageId, RenderLayer layer);
  void scheduleFullRender(const PageId& pageId);
  void scheduleDirtyRender(const PageId& pageId, const Rect& dirty);

  void tick();

  void setFrameRate(int fps);
  void setVSyncEnabled(bool enabled);

private:
  std::queue<RenderTask> tasks_;
  std::mutex mutex_;
};

}
```

### 11.3 渲染缓存

```cpp
namespace wb {

class RenderCache {
public:
  void put(const std::string& key, const std::string& texture);
  std::string get(const std::string& key);
  void invalidate(const std::string& key);
  void invalidateAll();
  void setMaxSize(size_t bytes);

private:
  std::unordered_map<std::string, std::string> cache_;
  size_t currentSize_ = 0;
  size_t maxSize_ = 256 * 1024 * 1024;
  std::mutex mutex_;
};

}
```

### 11.4 3D 渲染

```cpp
namespace wb {

struct Render3DRequest {
  ElementId elementId;
  int width;
  int height;
  Camera camera;
  std::vector<Light> lights;
  bool interactive;
};

struct Render3DResult {
  std::string textureId;
  int width;
  int height;
  bool cached;
};

class Render3D {
public:
  Render3DResult render(const Render3DRequest& request);
  void invalidate(const ElementId& elementId);

  int pickSurface(const ElementId& elementId, float x, float y);
  void setFaceColor(const ElementId& elementId, int faceId, const Color& color);
  void setMaterial(const ElementId& elementId, const Material& material);
  void transform(const ElementId& elementId, const Transform3D& transform);

private:
  std::unordered_map<ElementId, Scene> scenes_;
  std::mutex mutex_;
};

}
```

---

## 12. CRDT 与同步

### 12.1 CRDT 文档

```cpp
namespace wb {

class CrdtDocument {
public:
  void applyLocal(const std::string& operationJson);
  void applyRemote(const std::string& operationJson);

  std::string encodeState() const;
  void decodeState(const std::string& state);

  std::string encodeUpdate(const std::string& since) const;

  void merge(const CrdtDocument& other);

private:
  std::string state_;
  std::mutex mutex_;
};

}
```

### 12.2 同步管理

```cpp
namespace wb {

class SyncManager {
public:
  void connect(const std::string& endpoint, const std::string& token);
  void disconnect();
  bool isConnected() const;

  void sendOperation(const std::string& operationJson);
  void onOperation(std::function<void(const std::string&)> callback);

  void setOffline(bool offline);
  bool isOffline() const;

  void sync();

private:
  std::unique_ptr<SyncTransport> transport_;
  std::queue<std::string> pendingOps_;
  std::mutex mutex_;
};

}
```

### 12.3 音视频预留

```cpp
namespace wb {

class AVProvider {
public:
  virtual ~AVProvider() = default;
  virtual void startCall(const std::string& roomId) = 0;
  virtual void joinCall(const std::string& roomId) = 0;
  virtual void leaveCall() = 0;
  virtual void shareScreen(bool enable) = 0;
  virtual void startRecording() = 0;
  virtual void stopRecording() = 0;
};

}
```

### 12.4 互动白板预留

```cpp
namespace wb {

class InteractiveProvider {
public:
  virtual ~InteractiveProvider() = default;
  virtual void startSession(const std::string& sessionId) = 0;
  virtual void endSession() = 0;
  virtual void syncBoard(const std::string& boardId) = 0;
  virtual void sendEvent(const std::string& eventJson) = 0;
};

}
```

---

## 13. 权限与审计

### 13.1 权限

```cpp
namespace wb {

enum class Permission {
  Read,
  Write,
  Share,
  Admin,
};

class PermissionManager {
public:
  bool check(const UserId& userId, const BoardId& boardId, Permission perm);
  void grant(const UserId& userId, const BoardId& boardId, Permission perm);
  void revoke(const UserId& userId, const BoardId& boardId, Permission perm);

private:
  std::unordered_map<BoardId, std::unordered_map<UserId, Permission>> permissions_;
  std::mutex mutex_;
};

}
```

### 13.2 审计

```cpp
namespace wb {

struct AuditEntry {
  std::string id;
  Timestamp timestamp;
  UserId userId;
  std::string toolId;
  std::string argsJson;
  std::string resultJson;
  bool fromAI;
  std::string ip;
  std::string userAgent;
};

class AuditLog {
public:
  void log(const AuditEntry& entry);
  std::vector<AuditEntry> query(const std::string& filterJson);
  void exportToFile(const std::string& path);

private:
  std::vector<AuditEntry> entries_;
  std::mutex mutex_;
};

}
```

---

## 14. 序列化

### 14.1 序列化器

```cpp
namespace wb {

class Serializer {
public:
  std::string serialize(const Board& board);
  std::string serialize(const Page& page);
  std::string serialize(const Element& element);
  std::string serialize(const ToolResult& result);
};

class Deserializer {
public:
  Board deserializeBoard(const std::string& json);
  Page deserializePage(const std::string& json);
  Element deserializeElement(const std::string& json);
  ToolResult deserializeToolResult(const std::string& json);
};

}
```

### 14.2 二进制编解码

```cpp
namespace wb {

class BinaryCodec {
public:
  std::string encodeDisplayList(const DisplayList& list);
  DisplayList decodeDisplayList(const std::string& data);

  std::string encodeTexture(const std::string& texture);
  std::string decodeTexture(const std::string& data);
};

}
```

---

## 15. 线程模型

### 15.1 线程池

```cpp
namespace wb {

class ThreadPool {
public:
  explicit ThreadPool(int numThreads);
  ~ThreadPool();

  template <typename F>
  auto submit(F&& f) -> std::future<decltype(f())>;

  void shutdown();

private:
  std::vector<std::thread> workers_;
  std::queue<std::function<void()>> tasks_;
  std::mutex mutex_;
  std::condition_variable cv_;
  bool stop_ = false;
};

}
```

### 15.2 线程职责

| 线程 | 职责 |
|---|---|
| 主线程 | UI、输入、命令分发 |
| 渲染线程 | Display List 构建、2D 渲染 |
| 3D 线程 | 3D 渲染 |
| 缩略图线程 | 缩略图渲染 |
| CRDT 线程 | 合并、同步 |
| 文档线程 | PDF 解析、文本提取 |
| 网络线程 | 同步、AI 调用 |
| 音频线程 | 预留 |
| 视频线程 | 预留 |

### 15.3 线程安全

- 核心模型使用互斥锁保护
- 渲染使用独立快照
- 命令总线串行执行
- 异步任务使用 future

---

## 16. 性能优化

### 16.1 对象池

```cpp
namespace wb {

template <typename T>
class ObjectPool {
public:
  T* acquire();
  void release(T* obj);
  void reserve(size_t count);

private:
  std::vector<std::unique_ptr<T>> pool_;
  std::vector<T*> free_;
  std::mutex mutex_;
};

}
```

### 16.2 内存池

```cpp
namespace wb {

class MemoryPool {
public:
  void* allocate(size_t size);
  void deallocate(void* ptr);
  void reset();

  size_t used() const;
  size_t capacity() const;

private:
  std::vector<std::byte> buffer_;
  size_t offset_ = 0;
};

}
```

### 16.3 脏矩形

```cpp
namespace wb {

class DirtyRectManager {
public:
  void markDirty(const Rect& rect);
  void markFullDirty();
  std::vector<Rect> getDirtyRects();
  void clear();

private:
  std::vector<Rect> dirtyRects_;
  bool fullDirty_ = false;
  std::mutex mutex_;
};

}
```

---

## 17. 平台抽象

### 17.1 平台接口

```cpp
namespace wb {

class Platform {
public:
  virtual ~Platform() = default;

  virtual std::string getOS() const = 0;
  virtual std::string getVersion() const = 0;
  virtual std::string getLocale() const = 0;

  virtual void setClipboardText(const std::string& text) = 0;
  virtual std::string getClipboardText() = 0;

  virtual std::string getAppDataPath() const = 0;
  virtual std::string getTempPath() const = 0;

  virtual void showNotification(const std::string& title, const std::string& body) = 0;
};

}
```

### 17.2 窗口接口

```cpp
namespace wb {

class Window {
public:
  virtual ~Window() = default;

  virtual void setTitle(const std::string& title) = 0;
  virtual void setSize(int width, int height) = 0;
  virtual void setPosition(int x, int y) = 0;

  virtual void setTransparent(bool transparent) = 0;
  virtual void setAlwaysOnTop(bool onTop) = 0;
  virtual void setIgnoreMouseEvents(bool ignore, bool forward = false) = 0;

  virtual void show() = 0;
  virtual void hide() = 0;
  virtual void close() = 0;
};

}
```

---

## 18. 构建与打包

### 18.1 CMake

```cmake
cmake_minimum_required(VERSION 3.20)
project(wb_core CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(WB_BUILD_WASM "Build for WebAssembly" OFF)
option(WB_BUILD_TESTS "Build tests" ON)
option(WB_BUILD_BENCHMARKS "Build benchmarks" OFF)

add_library(wb_core STATIC
  src/base/...
  src/ffi/...
  src/command/...
  src/tool/...
  src/model/...
  src/page/...
  src/element/...
  src/render/...
  src/geometry/...
  src/crdt/...
  src/sync/...
  src/permission/...
  src/serialization/...
)

target_include_directories(wb_core PUBLIC include)

if(WB_BUILD_WASM)
  target_link_options(wb_core PUBLIC
    -s WASM=1
    -s EXPORTED_FUNCTIONS=...
    -s MODULARIZE=1
  )
endif()

if(WB_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
```

### 18.2 平台输出

| 平台 | 输出 |
|---|---|
| Windows | `wb_core.dll` |
| macOS | `libwb_core.dylib` |
| Linux | `libwb_core.so` |
| Web | `wb_core.wasm` |
| iOS | `libwb_core.a` |
| Android | `libwb_core.so` |

### 18.3 Flutter 集成

- 桌面端：动态库放 `native/` 目录，dart:ffi 加载
- Web 端：WASM 放 `assets/` 目录，`dart:js_interop` 加载
- iOS / Android：静态库或动态库

---

## 19. 测试

### 19.1 单元测试

```cpp
TEST(CommandBus, ExecuteCommand) {
  CommandBus bus;
  auto cmd = std::make_shared<CreateElementCommand>();
  bus.registerCommand(cmd);

  ToolContext ctx;
  ctx.argsJson = R"({"type":"sticky","text":"test"})";

  auto result = bus.execute("element.create", ctx);
  ASSERT_TRUE(result.ok());
}
```

### 19.2 集成测试

- 命令 + 模型 + 渲染
- CRDT 合并
- 页面管理
- 流程图布局
- 3D 渲染
- 函数渲染

### 19.3 性能测试

- 1000 元素渲染
- 100 页面切换
- 1000 次撤销重做
- 大流程图布局
- 3D 实时交互

---

## 20. 里程碑

### M1.1：基础层
- base 类型
- error
- log
- memory
- object pool

### M1.2：FFI 层
- C ABI
- 句柄管理
- JSON 协议
- 二进制协议

### M1.3：命令层
- Command
- CommandBus
- Transaction
- History
- Undo/Redo

### M1.4：Tool Registry
- ToolDefinition
- ToolRegistry
- ToolContext
- ToolResult

### M1.5：核心模型
- Board
- Page
- Element
- Connector
- Layer

### M1.6：页面管理
- PageManager
- 缩略图
- 页面操作

### M1.7：元素管理
- ElementManager
- 元素操作
- 命中测试

### M1.8：渲染层
- DisplayList
- RenderScheduler
- RenderCache
- 2D / 3D 渲染

### M1.9：CRDT 与同步
- CrdtDocument
- SyncManager
- 离线队列

### M1.10：权限与审计
- PermissionManager
- AuditLog

### M1.11：序列化
- Serializer
- Deserializer
- BinaryCodec

### M1.12：线程与性能
- ThreadPool
- 对象池
- 内存池
- 脏矩形

### M1.13：平台抽象
- Platform
- Window
- Input

### M1.14：构建与测试
- CMake
- 单元测试
- 集成测试
- 性能测试

---

## 21. 最终确认清单

| 项 | 确认结果 |
|---|---|
| C++ 标准 | C++20 |
| 跨平台 | Win / macOS / Linux / Web (WASM) |
| 跨语言 | dart:ffi + C ABI |
| 数据源 | C++ 核心唯一 |
| 命令层 | Command Bus |
| 工具层 | ToolRegistry |
| AI 调用 | 与用户一致 |
| 撤销 | 事务级 |
| 审计 | 全量 |
| 权限 | ACL |
| 同步 | CRDT |
| 离线 | 支持 |
| 3D | bgfx / Diligent |
| PDF | PDFium / MuPDF |
| 音视频 | 预留 |
| 互动白板 | 预留 |
| PPT | 暂不做 |
| MCP | 支持 |

---

## 22. 附录：接口命名规范

| 前缀 | 含义 |
|---|---|
| `wb_` | C ABI 导出 |
| `WB_API` | 导出宏 |
| `wb::` | C++ 命名空间 |
| `Command` | 命令类后缀 |
| `Manager` | 管理器后缀 |
| `Facade` | 门面后缀 |
| `Provider` | 提供者后缀 |
| `Registry` | 注册表后缀 |
| `Result<T>` | 结果类型 |
| `Error` | 错误类型 |

---

以上是《C++ 核心引擎接口设计 v1.0》完整内容。