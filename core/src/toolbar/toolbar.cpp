// toolbar/toolbar.cpp — domain "toolbar" (task package 1.4).
// Owns: core/src/toolbar.
//
// Ops (《可扩展工具栏设计》§3-5):
//   list    {}                 -> {"toolbar":default}  (no selection)
//   context {elementIds}       -> resolves by selection per §4.2:
//                                 0 ids -> default toolbar
//                                 1 id  -> toolbarForType(element.type)
//                                 >1    -> multiSelect toolbar
//                                -> {"resolved","toolbar","selection"}
//   invoke  {toolId,args?}     -> forwards to the tool domain executor
//                                (invokeDomain("tool","execute",...)) and
//                                passes its response through verbatim.
//
// Toolbar item ids are stable action ids ("canvas.background", "align.left",
// "shape.fill", ...); invoke toolIds are "domain.op" tool ids registered by
// the tool package ("page.setBackground", "theme.load", ...).

#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "../model/scene_store.h"
#include "wb/ffi/domain.h"

namespace wb {
namespace {

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

struct Item {
  const char* id;
  const char* label;
  const char* icon;
};

const std::vector<Item> kDefaultItems = {
    {"canvas.background", "背景", "palette"},
    {"canvas.grid", "网格", "grid"},
    {"view.zoom", "缩放", "zoom"},
    {"view.navigate", "导航", "navigate"},
    {"ai.open", "AI", "sparkle"},
    {"more.settings", "更多", "more"},
};

const std::vector<Item> kMultiSelectItems = {
    {"align.left", "左对齐", "align-left"},
    {"align.hcenter", "水平居中", "align-hcenter"},
    {"align.right", "右对齐", "align-right"},
    {"align.top", "顶对齐", "align-top"},
    {"align.vcenter", "垂直居中", "align-vcenter"},
    {"align.bottom", "底对齐", "align-bottom"},
    {"distribute.horizontal", "水平分布", "dist-h"},
    {"distribute.vertical", "垂直分布", "dist-v"},
    {"group", "分组", "group"},
    {"ungroup", "取消分组", "ungroup"},
    {"zorder.front", "置顶", "to-front"},
    {"zorder.back", "置底", "to-back"},
    {"style.color", "颜色", "color"},
    {"style.font", "字体", "font"},
    {"delete", "删除", "trash"},
};

const std::vector<Item> kStickyItems = {
    {"sticky.color", "颜色", "color"},       {"sticky.font", "字体", "font"},
    {"sticky.textAlign", "对齐", "align"},   {"sticky.autoSize", "自适应", "size"},
    {"sticky.duplicate", "复制", "copy"},    {"sticky.lock", "锁定", "lock"},
    {"delete", "删除", "trash"},
};

const std::vector<Item> kTextItems = {
    {"text.font", "字体", "font"},         {"text.bold", "加粗", "bold"},
    {"text.italic", "斜体", "italic"},     {"text.underline", "下划线", "underline"},
    {"text.color", "颜色", "color"},       {"text.align", "对齐", "align"},
    {"text.list", "列表", "list"},         {"delete", "删除", "trash"},
};

const std::vector<Item> kShapeItems = {
    {"shape.fill", "填充", "fill"},        {"shape.stroke", "描边", "stroke"},
    {"shape.strokeWidth", "线宽", "width"},{"shape.type", "形状", "shape"},
    {"shape.corner", "圆角", "corner"},    {"shape.shadow", "阴影", "shadow"},
    {"shape.duplicate", "复制", "copy"},   {"shape.layer", "层级", "layer"},
    {"delete", "删除", "trash"},
};

const std::vector<Item> kConnectorItems = {
    {"connector.lineStyle", "线型", "line"},
    {"connector.arrowStart", "起点箭头", "arrow-start"},
    {"connector.arrowEnd", "终点箭头", "arrow-end"},
    {"connector.waypoint", "路径点", "waypoint"},
    {"connector.label", "标签", "label"},
    {"delete", "删除", "trash"},
};

const std::vector<Item> kImageItems = {
    {"image.crop", "裁剪", "crop"},        {"image.replace", "替换", "replace"},
    {"image.filter", "滤镜", "filter"},    {"image.rotate", "旋转", "rotate"},
    {"image.flip", "翻转", "flip"},        {"image.opacity", "透明度", "opacity"},
    {"delete", "删除", "trash"},
};

const std::vector<Item> kRender3dItems = {
    {"3d.material", "材质", "material"},   {"3d.faceColor", "面颜色", "fill"},
    {"3d.light", "光照", "light"},         {"3d.transform", "变换", "transform"},
    {"3d.view", "视角", "view"},           {"3d.export", "导出", "export"},
    {"delete", "删除", "trash"},
};

const std::vector<Item> kFunctionItems = {
    {"function.expr", "表达式", "expr"},   {"function.lineStyle", "线型", "line"},
    {"function.range", "范围", "range"},   {"function.grid", "网格", "grid"},
    {"function.analyze", "分析", "analyze"},
    {"function.export", "导出", "export"}, {"delete", "删除", "trash"},
};

const std::vector<Item> kRender2dItems = {
    {"2d.style", "样式", "style"},         {"2d.brush", "笔刷", "brush"},
    {"2d.duration", "时长", "duration"},   {"2d.layer", "层级", "layer"},
    {"2d.export", "导出", "export"},       {"delete", "删除", "trash"},
};

const std::vector<Item> kTableItems = {
    {"table.rows", "行", "rows"},          {"table.cols", "列", "cols"},
    {"table.cellStyle", "单元格样式", "cell"},
    {"table.formula", "公式", "formula"},  {"table.merge", "合并", "merge"},
    {"delete", "删除", "trash"},
};

const std::vector<Item> kMindmapItems = {
    {"mindmap.addChild", "添加子节点", "child"},
    {"mindmap.addSibling", "添加同级", "sibling"},
    {"mindmap.layout", "布局", "layout"},  {"mindmap.theme", "主题", "theme"},
    {"mindmap.collapse", "折叠", "collapse"},
    {"delete", "删除", "trash"},
};

const std::vector<Item> kFlowchartItems = {
    {"flowchart.addNode", "添加节点", "node"},
    {"flowchart.connect", "连线", "connect"},
    {"flowchart.autoLayout", "自动布局", "layout"},
    {"flowchart.swimlane", "泳道", "swimlane"},
    {"flowchart.branchLabel", "分支标注", "branch"},
    {"delete", "删除", "trash"},
};

const std::vector<Item> kFrameItems = {
    {"frame.rename", "重命名", "rename"},  {"frame.fit", "适应内容", "fit"},
    {"frame.size", "尺寸", "size"},        {"frame.background", "背景", "palette"},
    {"delete", "删除", "trash"},
};

const std::vector<Item>* ItemsForContext(const std::string& context) {
  if (context == "multiSelect") return &kMultiSelectItems;
  if (context == "sticky") return &kStickyItems;
  if (context == "text") return &kTextItems;
  if (context == "shape") return &kShapeItems;
  if (context == "connector") return &kConnectorItems;
  if (context == "image") return &kImageItems;
  if (context == "render3d") return &kRender3dItems;
  if (context == "function") return &kFunctionItems;
  if (context == "render2d") return &kRender2dItems;
  if (context == "table") return &kTableItems;
  if (context == "mindmap") return &kMindmapItems;
  if (context == "flowchart") return &kFlowchartItems;
  if (context == "frame") return &kFrameItems;
  return &kDefaultItems;
}

nlohmann::json ToolbarJson(const std::string& context) {
  const std::vector<Item>* items = ItemsForContext(context);
  nlohmann::json list = nlohmann::json::array();
  for (const Item& item : *items) {
    nlohmann::json json;
    json["id"] = item.id;
    json["label"] = item.label;
    json["icon"] = item.icon;
    list.push_back(std::move(json));
  }
  nlohmann::json toolbar;
  toolbar["id"] = context;
  toolbar["items"] = std::move(list);
  return toolbar;
}

/// Element type -> context toolbar id per §4.1 (unknown types fall back).
std::string ContextForType(const std::string& type) {
  if (type == "sticky" || type == "note") return "sticky";
  if (type == "text") return "text";
  if (type == "shape" || type == "rect" || type == "circle" ||
      type == "diamond" || type == "parallelogram" || type == "ellipse") {
    return "shape";
  }
  if (type == "connector" || type == "arrow" || type == "line") return "connector";
  if (type == "image") return "image";
  if (type == "render3d" || type == "3d") return "render3d";
  if (type == "function") return "function";
  if (type == "render2d" || type == "2d") return "render2d";
  if (type == "table") return "table";
  if (type == "mindmap") return "mindmap";
  if (type == "flowchart") return "flowchart";
  if (type == "frame") return "frame";
  return "default";
}

class ToolbarDomain : public DomainHandler {
 public:
  std::string name() const override { return "toolbar"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "list") return List();
    if (op == "context") return Context(args);
    if (op == "invoke") return Invoke(args);
    return domainError("NotFound", "unknown toolbar op: " + op);
  }

 private:
  std::string List() {
    return domainOk(nlohmann::json{{"toolbar", ToolbarJson("default")}}.dump());
  }

  std::string Context(const nlohmann::json& args) {
    std::vector<std::string> elementIds;
    if (args.contains("elementIds") && args["elementIds"].is_array()) {
      for (const auto& id : args["elementIds"]) {
        if (id.is_string()) elementIds.push_back(id.get<std::string>());
      }
    }

    std::string resolved = "default";
    nlohmann::json types = nlohmann::json::array();
    if (elementIds.size() == 1) {
      using scene::SceneStore;
      std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
      const scene::ElementLocation location =
          SceneStore::instance().findElement(elementIds[0]);
      if (location.index < 0) {
        return domainError("NotFound", "unknown element: " + elementIds[0]);
      }
      const nlohmann::json& element =
          location.page->elements[static_cast<std::size_t>(location.index)];
      const std::string type = element.value("type", std::string());
      types.push_back(type);
      resolved = ContextForType(type);
    } else if (elementIds.size() > 1) {
      using scene::SceneStore;
      std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
      for (const std::string& id : elementIds) {
        const scene::ElementLocation location = SceneStore::instance().findElement(id);
        if (location.index < 0) {
          return domainError("NotFound", "unknown element: " + id);
        }
        types.push_back(location.page->elements[static_cast<std::size_t>(
                                                       location.index)]
                            .value("type", std::string()));
      }
      resolved = "multiSelect";
    }

    nlohmann::json selection;
    selection["count"] = static_cast<int>(elementIds.size());
    selection["types"] = std::move(types);
    nlohmann::json result;
    result["resolved"] = resolved;
    result["toolbar"] = ToolbarJson(resolved);
    result["selection"] = std::move(selection);
    return domainOk(result.dump());
  }

  std::string Invoke(const nlohmann::json& args) {
    const std::string toolId = args.value("toolId", std::string());
    if (toolId.empty()) {
      return domainError("InvalidArgument", "args.toolId is required");
    }
    nlohmann::json executeArgs;
    executeArgs["toolId"] = toolId;
    if (args.contains("args")) {
      executeArgs["args"] = args["args"];
    }
    // Forward through the tool package; its response (including errors such
    // as NotFound for unregistered toolIds) passes through verbatim.
    return invokeDomain("tool", "execute", executeArgs.dump());
  }
};

}  // namespace

WB_REGISTER_DOMAIN(ToolbarDomain)

}  // namespace wb
