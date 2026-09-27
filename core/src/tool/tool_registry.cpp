// tool/tool_registry.cpp — ToolRegistry (task package 1.2).
// Owns: core/src/tool. Per design docs《可扩展工具栏设计》§3,
//《C++ 核心引擎接口设计》§7 (tool layer).
//
// Domain "tool" ops:
//   list    {}                      -> {"tools":[...], "count":N}
//   get     {toolId}                -> {"tool":{...}} | NotFound
//   execute {toolId, args}          -> forwards to invokeDomain(domain, op, args)
//
// Tool ids are "domain.op" strings. The prefix maps through MapDomain
// ("3d" -> "render3d"); execution forwards the raw args object, so tools are
// pure renames of domain operations with discoverable metadata.

#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "wb/ffi/domain.h"

namespace wb {
namespace {

constexpr const char* kTag = "tool";

struct ToolInfo {
  const char* id;
  const char* name;      // Chinese display name (per《工具栏》naming)
  const char* category;
  const char* description;
};

const ToolInfo kTools[] = {
    // Board
    {"board.create", "新建白板", "board", "创建白板并返回句柄"},
    {"board.get", "获取白板", "board", "读取白板整体状态"},
    {"board.destroy", "销毁白板", "board", "释放白板及其资源"},
    // Page
    {"page.list", "页面列表", "page", "列出白板内全部页面"},
    {"page.create", "新建页面", "page", "在白板末尾新建页面"},
    {"page.duplicate", "复制页面", "page", "深拷贝页面及其元素"},
    {"page.delete", "删除页面", "page", "删除页面"},
    {"page.move", "移动页面", "page", "调整页面排序"},
    {"page.rename", "重命名页面", "page", "修改页面名称"},
    {"page.setBackground", "设置背景", "page", "设置页面背景样式"},
    {"page.lock", "锁定页面", "page", "锁定/解锁页面编辑"},
    {"page.hide", "隐藏页面", "page", "隐藏/显示页面"},
    // Element
    {"element.create", "创建元素", "element", "创建白板元素"},
    {"element.update", "更新元素", "element", "增量更新元素属性"},
    {"element.delete", "删除元素", "element", "删除元素并级联清理连线"},
    {"element.list", "元素列表", "element", "列出页面内全部元素"},
    {"element.batch", "批量操作", "element", "批量创建/更新/删除元素"},
    // Geometry / layout
    {"geometry.hitTest", "命中测试", "geometry", "点选命中的元素"},
    {"geometry.bounds", "包围盒", "geometry", "计算元素包围盒"},
    {"layout.align", "对齐", "layout", "多元素对齐"},
    {"layout.distribute", "分布", "layout", "多元素等距分布"},
    {"layout.snap", "吸附", "layout", "拖动吸附辅助"},
    // Render
    {"render.getDisplayList", "显示列表", "render", "获取页面显示列表"},
    {"render.thumbnail", "缩略图", "render", "生成页面缩略图"},
    {"render.cacheStats", "缓存统计", "render", "渲染缓存统计"},
    {"render.cacheClear", "清空缓存", "render", "清空渲染缓存"},
    {"render.perfStats", "性能统计", "render", "渲染性能指标"},
    // 2D
    {"render2d.create", "创建图形", "render2d", "创建 2D 图形元素"},
    {"render2d.setStyle", "图形样式", "render2d", "设置 2D 图形样式"},
    {"render2d.annotate", "图形批注", "render2d", "为图形添加批注"},
    // Theme / background
    {"theme.load", "加载主题", "theme", "切换/加载主题"},
    {"theme.current", "当前主题", "theme", "读取当前主题"},
    {"theme.list", "主题列表", "theme", "列出内置主题"},
    {"background.list", "背景列表", "background", "列出背景预设"},
    {"background.set", "应用背景", "background", "为页面应用背景预设"},
    // Radial
    {"radial.layout", "圆盘布局", "radial", "计算齿轮圆盘布局"},
    {"radial.hitTest", "圆盘命中", "radial", "圆盘点击命中测试"},
    {"radial.stateCreate", "圆盘状态", "radial", "创建圆盘交互状态"},
    {"radial.stateGet", "读取圆盘状态", "radial", "读取圆盘交互状态"},
    // Toolbar / sidebar
    {"toolbar.list", "工具栏列表", "toolbar", "主工具栏工具清单"},
    {"toolbar.context", "上下文工具栏", "toolbar", "按选中元素解析上下文工具"},
    {"toolbar.invoke", "工具栏调用", "toolbar", "调用工具栏动作"},
    {"sidebar.toggle", "侧栏开关", "sidebar", "展开/收起左侧栏"},
    {"sidebar.setWidth", "侧栏宽度", "sidebar", "设置左侧栏宽度"},
    // Annotation
    {"annotation.enterTransparent", "进入透明批注", "annotation", "进入透明批注模式"},
    {"annotation.exitTransparent", "退出透明批注", "annotation", "退出透明批注模式"},
    {"annotation.setPenetrate", "穿透开关", "annotation", "切换鼠标穿透"},
    {"annotation.addStroke", "添加笔迹", "annotation", "添加批注笔迹"},
    {"annotation.undo", "批注撤销", "annotation", "撤销批注笔迹"},
    {"annotation.redo", "批注重做", "annotation", "重做批注笔迹"},
    {"annotation.clear", "清空批注", "annotation", "清空批注层"},
    {"annotation.saveToBoard", "保存批注", "annotation", "将批注保存到白板"},
    {"annotation.state", "批注状态", "annotation", "读取批注模式状态"},
    // Function plot
    {"function.create", "创建函数图", "function", "创建函数图像元素"},
    {"function.add", "添加表达式", "function", "添加函数表达式"},
    {"function.setStyle", "函数样式", "function", "设置函数图样式"},
    {"function.analyze", "函数分析", "function", "零点/极值/对称性分析"},
    {"function.export", "导出函数", "function", "导出采样数据"},
    // Flowchart
    {"flowchart.create", "创建流程图", "flowchart", "创建流程图容器"},
    {"flowchart.autoLayout", "自动布局", "flowchart", "流程图自动布局"},
    {"flowchart.toSwimlane", "泳道化", "flowchart", "转换为泳道图"},
    {"flowchart.labelBranches", "分支标注", "flowchart", "标注是/否分支"},
    // Mindmap
    {"mindmap.create", "创建思维导图", "mindmap", "创建思维导图容器"},
    {"mindmap.addNode", "添加节点", "mindmap", "添加导图节点"},
    {"mindmap.removeNode", "删除节点", "mindmap", "删除导图节点"},
    {"mindmap.setLayout", "导图布局", "mindmap", "设置布局算法与方向"},
    {"mindmap.setStyle", "导图样式", "mindmap", "设置导图样式"},
    {"mindmap.layout", "重排导图", "mindmap", "重新计算导图布局"},
    {"mindmap.export", "导出导图", "mindmap", "导出为大纲"},
    {"mindmap.list", "导图列表", "mindmap", "列出全部思维导图"},
    // Table
    {"table.create", "创建表格", "table", "创建表格元素"},
    {"table.setCell", "写入单元格", "table", "设置单元格内容"},
    {"table.getCell", "读取单元格", "table", "读取单元格内容"},
    {"table.setFormula", "设置公式", "table", "设置单元格公式"},
    {"table.sort", "表格排序", "table", "按列排序表格"},
    {"table.filter", "表格筛选", "table", "按条件筛选行"},
    {"table.setStyle", "表格样式", "table", "设置表格样式"},
    {"table.list", "表格列表", "table", "列出全部表格"},
    // CRDT
    {"crdt.create", "创建副本", "crdt", "创建 CRDT 文档副本"},
    {"crdt.applyLocal", "本地操作", "crdt", "应用本地变更"},
    {"crdt.applyRemote", "远程操作", "crdt", "应用远端变更"},
    {"crdt.encodeState", "编码状态", "crdt", "编码完整文档状态"},
    {"crdt.decodeState", "解码状态", "crdt", "从状态重建文档"},
    {"crdt.encodeUpdate", "编码增量", "crdt", "编码增量更新"},
    {"crdt.merge", "合并副本", "crdt", "合并两份副本"},
    {"crdt.list", "副本列表", "crdt", "列出全部副本"},
    // 3D
    {"3d.create", "创建3D元素", "render3d", "创建 3D 几何元素"},
    {"3d.render", "渲染3D", "render3d", "离屏渲染 3D 视图"},
    {"3d.pickSurface", "表面拾取", "render3d", "拾取 3D 表面"},
    {"3d.setFaceColor", "面颜色", "render3d", "设置表面颜色"},
    {"3d.setMaterial", "材质", "render3d", "设置材质参数"},
    {"3d.setLight", "光照", "render3d", "设置光照参数"},
    {"3d.transform", "变换3D", "render3d", "旋转/缩放/平移"},
    {"3d.export", "导出3D", "render3d", "导出 OBJ/JSON"},
    // Document
    {"document.import", "导入文档", "document", "导入 PDF 文档"},
    {"document.info", "文档信息", "document", "读取文档页数与元数据"},
    {"document.setPage", "文档翻页", "document", "切换到指定页"},
    {"document.list", "文档列表", "document", "列出已导入文档"},
    // AI
    {"ai.sessionCreate", "创建AI会话", "ai", "创建 AI 助手会话"},
    {"ai.sessionClose", "关闭AI会话", "ai", "关闭 AI 会话"},
    {"ai.sessionGet", "读取AI会话", "ai", "读取 AI 会话状态"},
    {"ai.sendMessage", "发送消息", "ai", "向 AI 发送文本消息"},
    {"ai.sendAudio", "发送语音", "ai", "发送语音消息"},
    {"ai.listMessages", "消息列表", "ai", "读取会话消息"},
    {"ai.executeToolCall", "执行AI工具", "ai", "执行 AI 生成的工具调用"},
    {"ai.previewToolCall", "预览工具调用", "ai", "预览 AI 工具调用效果"},
    {"ai.cancelToolCall", "取消工具调用", "ai", "取消待执行的工具调用"},
    {"ai.setContext", "设置上下文", "ai", "设置 AI 会话上下文"},
    // MCP
    {"mcp.start", "启动MCP", "mcp", "启动 MCP 服务"},
    {"mcp.stop", "停止MCP", "mcp", "停止 MCP 服务"},
    {"mcp.isRunning", "MCP状态", "mcp", "查询 MCP 服务状态"},
    {"mcp.handleRequest", "MCP请求", "mcp", "处理 JSON-RPC 请求"},
    {"mcp.sessionCreate", "创建MCP会话", "mcp", "创建 MCP 客户端会话"},
    {"mcp.sessionGet", "读取MCP会话", "mcp", "读取 MCP 会话状态"},
    {"mcp.sessionClose", "关闭MCP会话", "mcp", "关闭 MCP 会话"},
    {"mcp.listTools", "MCP工具列表", "mcp", "列出 MCP 工具"},
    {"mcp.callTool", "调用MCP工具", "mcp", "调用 MCP 工具"},
    {"mcp.listResources", "MCP资源列表", "mcp", "列出 MCP 资源"},
    {"mcp.readResource", "读取MCP资源", "mcp", "读取 MCP 资源内容"},
    {"mcp.listPrompts", "MCP提示模板", "mcp", "列出 MCP 提示模板"},
    {"mcp.getPrompt", "渲染MCP提示", "mcp", "渲染 MCP 提示模板"},
    {"mcp.auditQuery", "MCP审计查询", "mcp", "查询审计日志"},
    {"mcp.auditExport", "MCP审计导出", "mcp", "导出审计日志"},
    // Sync / permission / audit
    {"sync.connect", "连接同步", "sync", "连接协作服务"},
    {"sync.disconnect", "断开同步", "sync", "断开协作服务"},
    {"sync.status", "同步状态", "sync", "读取同步状态"},
    {"sync.setOffline", "离线开关", "sync", "切换离线模式"},
    {"sync.sendOperation", "发送操作", "sync", "发送操作到协作服务"},
    {"sync.sync", "手动同步", "sync", "立即推送并拉取变更"},
    {"sync.queue", "离线队列", "sync", "读取待同步队列"},
    {"sync.capabilities", "能力查询", "sync", "读取同步能力与提供者"},
    {"permission.check", "权限检查", "permission", "检查用户权限"},
    {"permission.grant", "授予权限", "permission", "授予用户权限"},
    {"permission.revoke", "撤销权限", "permission", "撤销用户权限"},
    {"permission.list", "权限列表", "permission", "列出白板授权"},
    {"permission.levels", "权限级别", "permission", "列出权限级别定义"},
    {"audit.log", "写入审计", "audit", "写入审计条目"},
    {"audit.query", "审计查询", "audit", "查询审计日志"},
    {"audit.export", "导出审计", "audit", "导出审计日志"},
    {"audit.clear", "清空审计", "audit", "清空审计日志"},
    // Command
    {"command.undo", "撤销", "command", "撤销上一步操作"},
    {"command.redo", "重做", "command", "重做已撤销操作"},
    {"command.history", "历史记录", "command", "读取撤销重做历史"},
};

constexpr std::size_t kToolCount = sizeof(kTools) / sizeof(kTools[0]);

std::string MapDomain(const std::string& prefix) {
  if (prefix == "3d") return "render3d";
  return prefix;
}

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

nlohmann::json ToJson(const ToolInfo& tool) {
  nlohmann::json item;
  item["id"] = tool.id;
  item["name"] = tool.name;
  item["category"] = tool.category;
  item["description"] = tool.description;
  return item;
}

const ToolInfo* FindTool(const std::string& toolId) {
  for (const ToolInfo& tool : kTools) {
    if (toolId == tool.id) return &tool;
  }
  return nullptr;
}

class ToolDomain : public DomainHandler {
 public:
  std::string name() const override { return kTag; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    if (op == "list") {
      nlohmann::json tools = nlohmann::json::array();
      for (const ToolInfo& tool : kTools) {
        tools.push_back(ToJson(tool));
      }
      nlohmann::json result;
      result["tools"] = std::move(tools);
      result["count"] = kToolCount;
      return domainOk(result.dump());
    }
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "get") {
      const std::string toolId = args.value("toolId", std::string());
      const ToolInfo* tool = FindTool(toolId);
      if (tool == nullptr) {
        return domainError("NotFound", "unknown tool: " + toolId);
      }
      return domainOk(nlohmann::json{{"tool", ToJson(*tool)}}.dump());
    }
    if (op == "execute") {
      const std::string toolId = args.value("toolId", std::string());
      const std::size_t dot = toolId.find('.');
      if (dot == std::string::npos || dot == 0 || dot + 1 >= toolId.size()) {
        return domainError("InvalidArgument",
                           "toolId must be 'domain.op': " + toolId);
      }
      const std::string domain = MapDomain(toolId.substr(0, dot));
      const std::string toolOp = toolId.substr(dot + 1);
      nlohmann::json toolArgs = nlohmann::json::object();
      if (args.contains("args") && args["args"].is_object()) {
        toolArgs = args["args"];
      } else if (args.contains("args") && args["args"].is_array()) {
        toolArgs = nlohmann::json::object();  // unexpected shape: forward empty
      }
      return invokeDomain(domain, toolOp, toolArgs.dump());
    }
    return domainError("NotFound", "unknown tool op: " + op);
  }
};

}  // namespace

WB_REGISTER_DOMAIN(ToolDomain)

}  // namespace wb
