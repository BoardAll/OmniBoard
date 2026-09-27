// mindmap/mindmap.cpp — domain "mindmap" (task package 1.5).
// Owns: core/src/mindmap.
//
// Ops (《AI/MCP》§7 / 《MCP_Server》§11): create, addNode(add_node),
// removeNode(remove_node), setLayout(set_layout), setStyle(set_style),
// layout, export, list.
//
// The element data holds a single `root` tree node; layout fills each node's
// box so the renderer can draw the tree without recomputing it.
//   tree   -> right-growing tidy tree (leaf rows + depth columns)
//   radial -> rings around the root, angular spans proportional to leaf count
//
// Node box: width = codepointCount*8 + 24 (min 48), height = 32.

#include <algorithm>
#include <cmath>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "../model/scene_store.h"
#include "wb/ffi/domain.h"
#include "wb/platform/platform.h"

namespace wb {
namespace {

using scene::SceneStore;
using scene::PageRec;

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

void Renumber(std::vector<nlohmann::json>& elements) {
  for (std::size_t i = 0; i < elements.size(); ++i) {
    elements[i]["zIndex"] = static_cast<int>(i);
  }
}

constexpr double kNodeHeight = 32.0;
constexpr double kRowGap = 20.0;      // tree: gap between leaf rows
constexpr double kColumnGap = 60.0;   // tree: gap between depth columns
constexpr double kRingGap = 160.0;    // radial: radius step per depth

/// UTF-8 aware length so CJK labels get reasonably wide boxes.
std::size_t TextLength(const std::string& text) {
  std::size_t count = 0;
  for (unsigned char ch : text) {
    if ((ch & 0xC0) != 0x80) ++count;
  }
  return count;
}

double NodeWidth(const nlohmann::json& node) {
  const std::size_t length = TextLength(node.value("text", std::string()));
  return std::max(48.0, static_cast<double>(length) * 8.0 + 24.0);
}

/// Picks the element id from args: `mindmapId` first, then `elementId`.
std::string ElementIdArg(const nlohmann::json& args) {
  const std::string mindmapId = args.value("mindmapId", std::string());
  if (!mindmapId.empty()) return mindmapId;
  return args.value("elementId", std::string());
}

/// Depth-first walk over the root tree; visitor receives (node, depth).
void WalkTree(nlohmann::json& node, int depth,
              const std::function<void(nlohmann::json&, int)>& visitor) {
  visitor(node, depth);
  nlohmann::json& children = node["children"];
  for (nlohmann::json& child : children) {
    WalkTree(child, depth + 1, visitor);
  }
}

nlohmann::json* FindNode(nlohmann::json& node, const std::string& id) {
  if (node.value("id", std::string()) == id) return &node;
  for (nlohmann::json& child : node["children"]) {
    if (nlohmann::json* found = FindNode(child, id)) return found;
  }
  return nullptr;
}

int CountNodes(const nlohmann::json& node) {
  int count = 1;
  for (const nlohmann::json& child : node["children"]) {
    count += CountNodes(child);
  }
  return count;
}

std::size_t LeafCount(const nlohmann::json& node) {
  if (node["children"].empty()) return 1;
  std::size_t count = 0;
  for (const nlohmann::json& child : node["children"]) {
    count += LeafCount(child);
  }
  return count;
}

/// Next "mm-N" id across the whole tree.
std::string NextNodeId(const nlohmann::json& root) {
  long long maxIndex = 0;
  std::function<void(const nlohmann::json&)> visit = [&](const nlohmann::json& node) {
    const std::string id = node.value("id", std::string());
    if (id.rfind("mm-", 0) == 0) {
      try {
        maxIndex = std::max(maxIndex, std::stoll(id.substr(3)));
      } catch (...) {
      }
    }
    for (const nlohmann::json& child : node["children"]) visit(child);
  };
  visit(root);
  return "mm-" + std::to_string(maxIndex + 1);
}

/// Recursively normalizes a node: id/text/children/style/box fields.
void NormalizeNode(nlohmann::json& node, const std::string& fallbackId) {
  if (!node.is_object()) node = nlohmann::json::object();
  if (node.value("id", std::string()).empty()) node["id"] = fallbackId;
  if (!node.contains("text")) node["text"] = "";
  if (!node.contains("children") || !node["children"].is_array()) {
    node["children"] = nlohmann::json::array();
  }
  node["width"] = node.value("width", 0.0) > 0.0 ? node["width"].get<double>()
                                                 : NodeWidth(node);
  node["height"] = kNodeHeight;
  node["x"] = node.value("x", 0.0);
  node["y"] = node.value("y", 0.0);
  for (nlohmann::json& child : node["children"]) {
    NormalizeNode(child, "mm-0");
  }
}

class MindmapDomain : public DomainHandler {
 public:
  std::string name() const override { return "mindmap"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "create") return Create(args);
    if (op == "addNode" || op == "add_node") return AddNode(args);
    if (op == "removeNode" || op == "remove_node" || op == "remove") {
      return RemoveNode(args);
    }
    if (op == "setLayout" || op == "set_layout") return SetLayout(args);
    if (op == "setStyle" || op == "set_style") return SetStyle(args);
    if (op == "layout" || op == "autoLayout" || op == "relayout") {
      return Layout(args);
    }
    if (op == "export") return Export(args);
    if (op == "list") return List(args);
    return domainError("NotFound", "unknown mindmap op: " + op);
  }

 private:
  /// Finds a "mindmap" element; fills errorCode/errorMessage on failure.
  nlohmann::json* Find(SceneStore& store, const std::string& elementId,
                       std::string* errorCode, std::string* errorMessage) {
    const scene::ElementLocation location = store.findElement(elementId);
    if (location.index < 0) {
      *errorCode = "NotFound";
      *errorMessage = "unknown element: " + elementId;
      return nullptr;
    }
    if (location.page->locked) {
      *errorCode = "Conflict";
      *errorMessage = "page is locked: " + location.page->id;
      return nullptr;
    }
    nlohmann::json& element =
        location.page->elements[static_cast<std::size_t>(location.index)];
    if (element.value("type", std::string()) != "mindmap") {
      *errorCode = "InvalidArgument";
      *errorMessage = "element is not a mindmap: " + elementId;
      return nullptr;
    }
    return &element;
  }

  static nlohmann::json DefaultData() {
    nlohmann::json root;
    root["id"] = "mm-1";
    root["text"] = "中心主题";
    root["children"] = nlohmann::json::array();
    nlohmann::json data;
    data["root"] = std::move(root);
    data["layout"] = "tree";
    data["theme"] = "default";
    return data;
  }

  // --- ops ------------------------------------------------------------------
  std::string Create(const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    PageRec* page = SceneStore::instance().findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    if (page->locked) {
      return domainError("Conflict", "page is locked: " + pageId);
    }
    nlohmann::json element = args.value("element", nlohmann::json::object());
    if (!element.is_object()) element = nlohmann::json::object();
    element["type"] = "mindmap";

    nlohmann::json data = DefaultData();
    bool hasRoot = false;
    std::string shorthandText;
    if (element.contains("data") && element["data"].is_object()) {
      hasRoot = element["data"].contains("root") &&
                element["data"]["root"].is_object();
      shorthandText = element["data"].value("text", std::string());
      for (auto it = element["data"].begin(); it != element["data"].end(); ++it) {
        if (it.key() == std::string("text")) continue;
        data[it.key()] = it.value();
      }
    }
    if (!data.contains("root") || !data["root"].is_object()) {
      data["root"] = DefaultData()["root"];
      if (!hasRoot && !shorthandText.empty()) {
        data["root"]["text"] = shorthandText;
      }
    }
    const std::string layout = data.value("layout", std::string("tree"));
    data["layout"] = (layout == "tree" || layout == "radial") ? layout : "tree";
    NormalizeNode(data["root"], "mm-1");
    element["data"] = std::move(data);

    std::string elementId = element.value("id", std::string());
    if (elementId.empty()) elementId = SceneStore::instance().newElementId();
    const std::int64_t now = timeMillis();
    element["id"] = elementId;
    element["pageId"] = pageId;
    element["createdAt"] = element.value("createdAt", now);
    element["updatedAt"] = now;
    element["rotation"] = element.value("rotation", 0.0f);
    element["opacity"] = element.value("opacity", 1.0f);
    element["locked"] = element.value("locked", false);

    int index = static_cast<int>(page->elements.size());
    if (element.contains("zIndex") && element["zIndex"].is_number_integer()) {
      index = std::max(0, std::min(element["zIndex"].get<int>(), index));
    }
    element["zIndex"] = index;
    page->elements.insert(page->elements.begin() + index, std::move(element));
    Renumber(page->elements);

    nlohmann::json& created =
        page->elements[static_cast<std::size_t>(index)];
    nlohmann::json result;
    result["element"] = created;
    result["elementId"] = elementId;
    result["pageId"] = pageId;
    result["type"] = "mindmap";
    return domainOk(result.dump());
  }

  std::string AddNode(const nlohmann::json& args) {
    const std::string mindmapId = ElementIdArg(args);
    nlohmann::json spec = args.value("node", nlohmann::json::object());
    if (!spec.is_object()) spec = nlohmann::json::object();
    const std::string text =
        spec.value("text", args.value("text", std::string()));
    if (text.empty()) {
      return domainError("InvalidArgument", "args.text is required");
    }
    const std::string parentId =
        spec.value("parentId", args.value("parentId", std::string()));
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), mindmapId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& root = (*element)["data"]["root"];
    nlohmann::json* parent = nullptr;
    if (parentId.empty()) {
      parent = &root;
    } else {
      parent = FindNode(root, parentId);
    }
    if (parent == nullptr) {
      return domainError("NotFound", "unknown node: " + parentId);
    }
    nlohmann::json child;
    child["id"] = NextNodeId(root);
    child["text"] = text;
    child["children"] = nlohmann::json::array();
    child["width"] = NodeWidth(child);
    child["height"] = kNodeHeight;
    child["x"] = 0.0;
    child["y"] = 0.0;
    (*parent)["children"].push_back(child);
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["node"] = (*parent)["children"].back();
    result["nodeCount"] = CountNodes(root);
    result["mindmapId"] = mindmapId;
    return domainOk(result.dump());
  }

  std::string RemoveNode(const nlohmann::json& args) {
    const std::string mindmapId = ElementIdArg(args);
    const std::string nodeId = args.value("nodeId", std::string());
    if (nodeId.empty()) {
      return domainError("InvalidArgument", "args.nodeId is required");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), mindmapId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& root = (*element)["data"]["root"];
    if (root.value("id", std::string()) == nodeId) {
      return domainError("InvalidArgument", "cannot remove the root node");
    }
    bool removed = false;
    std::function<void(nlohmann::json&)> visit = [&](nlohmann::json& node) {
      nlohmann::json& children = node["children"];
      const std::size_t before = children.size();
      children.erase(std::remove_if(children.begin(), children.end(),
                                    [&nodeId](const nlohmann::json& child) {
                                      return child.value("id", std::string()) ==
                                             nodeId;
                                    }),
                     children.end());
      if (children.size() != before) {
        removed = true;
        return;
      }
      for (nlohmann::json& child : children) {
        visit(child);
        if (removed) return;
      }
    };
    visit(root);
    if (!removed) {
      return domainError("NotFound", "unknown node: " + nodeId);
    }
    (*element)["updatedAt"] = timeMillis();
    nlohmann::json result;
    result["mindmapId"] = mindmapId;
    result["nodeCount"] = CountNodes(root);
    return domainOk(result.dump());
  }

  std::string SetLayout(const nlohmann::json& args) {
    const std::string mindmapId = ElementIdArg(args);
    std::string layout = args.value("layout", std::string());
    if (layout == "right" || layout == "logicalStructure") layout = "tree";
    if (layout != "tree" && layout != "radial") {
      return domainError("InvalidArgument", "unknown layout: " + layout);
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), mindmapId, &code, &message);
    if (element == nullptr) return domainError(code, message);
    (*element)["data"]["layout"] = layout;
    (*element)["updatedAt"] = timeMillis();
    nlohmann::json result;
    result["layout"] = layout;
    result["mindmapId"] = mindmapId;
    return domainOk(result.dump());
  }

  std::string SetStyle(const nlohmann::json& args) {
    const std::string mindmapId = ElementIdArg(args);
    if (!args.contains("style") || !args["style"].is_object()) {
      return domainError("InvalidArgument", "args.style is required");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), mindmapId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    const std::string nodeId = args.value("nodeId", std::string());
    const nlohmann::json& style = args["style"];
    if (!nodeId.empty()) {
      nlohmann::json* node = FindNode((*element)["data"]["root"], nodeId);
      if (node == nullptr) {
        return domainError("NotFound", "unknown node: " + nodeId);
      }
      nlohmann::json merged = node->value("style", nlohmann::json::object());
      if (!merged.is_object()) merged = nlohmann::json::object();
      for (auto it = style.begin(); it != style.end(); ++it) {
        merged[it.key()] = it.value();
      }
      (*node)["style"] = std::move(merged);
    } else {
      nlohmann::json merged = element->value("style", nlohmann::json::object());
      if (!merged.is_object()) merged = nlohmann::json::object();
      for (auto it = style.begin(); it != style.end(); ++it) {
        merged[it.key()] = it.value();
      }
      (*element)["style"] = std::move(merged);
    }
    (*element)["updatedAt"] = timeMillis();
    nlohmann::json result;
    result["element"] = *element;
    result["elementId"] = mindmapId;
    return domainOk(result.dump());
  }

  std::string Layout(const nlohmann::json& args) {
    const std::string mindmapId = ElementIdArg(args);
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), mindmapId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& data = (*element)["data"];
    nlohmann::json& root = data["root"];
    const std::string layout = data.value("layout", std::string("tree"));
    if (layout == "radial") {
      LayoutRadial(root);
    } else {
      LayoutTree(root);
    }
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json nodes = nlohmann::json::array();
    WalkTree(root, 0, [&nodes](nlohmann::json& node, int depth) {
      nlohmann::json item;
      item["id"] = node.value("id", std::string());
      item["x"] = node.value("x", 0.0);
      item["y"] = node.value("y", 0.0);
      item["width"] = node.value("width", 0.0);
      item["height"] = node.value("height", kNodeHeight);
      item["depth"] = depth;
      nodes.push_back(std::move(item));
    });
    nlohmann::json result;
    result["mindmapId"] = mindmapId;
    result["layout"] = layout;
    result["nodeCount"] = CountNodes(root);
    result["nodes"] = std::move(nodes);
    return domainOk(result.dump());
  }

  std::string Export(const nlohmann::json& args) {
    const std::string mindmapId = ElementIdArg(args);
    const std::string format = args.value("format", std::string("json"));
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), mindmapId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    const nlohmann::json& root = (*element)["data"]["root"];
    nlohmann::json result;
    result["mindmapId"] = mindmapId;
    result["nodeCount"] = CountNodes(root);
    if (format == "markdown" || format == "md") {
      std::string content = "# " + root.value("text", std::string()) + "\n";
      std::function<void(const nlohmann::json&, int)> visit =
          [&](const nlohmann::json& node, int depth) {
            for (const nlohmann::json& child : node["children"]) {
              content += std::string(static_cast<std::size_t>(depth) * 2, ' ') +
                         "- " + child.value("text", std::string()) + "\n";
              visit(child, depth + 1);
            }
          };
      visit(root, 1);
      result["format"] = "markdown";
      result["content"] = std::move(content);
    } else if (format == "json") {
      result["format"] = "json";
      result["tree"] = root;
    } else {
      return domainError("InvalidArgument", "unknown export format: " + format);
    }
    return domainOk(result.dump());
  }

  std::string List(const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    PageRec* page = SceneStore::instance().findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    nlohmann::json elements = nlohmann::json::array();
    for (const nlohmann::json& element : page->elements) {
      if (element.value("type", std::string()) != "mindmap") continue;
      nlohmann::json summary = SceneStore::elementSummary(element);
      int nodeCount = 0;
      std::string layout = "tree";
      if (element.contains("data") && element["data"].is_object()) {
        const nlohmann::json& data = element["data"];
        layout = data.value("layout", std::string("tree"));
        if (data.contains("root") && data["root"].is_object()) {
          nodeCount = CountNodes(data["root"]);
        }
      }
      summary["nodeCount"] = nodeCount;
      summary["layout"] = layout;
      elements.push_back(std::move(summary));
    }
    nlohmann::json result;
    result["elements"] = std::move(elements);
    result["count"] = static_cast<int>(result["elements"].size());
    return domainOk(result.dump());
  }

  // --- layout helpers -------------------------------------------------------
  /// Right-growing tidy tree; leaf rows at kRowGap, final root centre at 0,0.
  static void LayoutTree(nlohmann::json& root) {
    std::map<int, double> depthWidth;
    WalkTree(root, 0, [&depthWidth](nlohmann::json& node, int depth) {
      const double width = NodeWidth(node);
      node["width"] = width;
      node["height"] = kNodeHeight;
      depthWidth[depth] = std::max(depthWidth[depth], width);
    });
    std::map<int, double> depthX;
    double cursor = 0.0;
    for (auto& [depth, width] : depthWidth) {
      depthX[depth] = cursor;
      cursor += width + kColumnGap;
    }
    double nextRow = 0.0;
    std::function<void(nlohmann::json&, int)> place = [&](nlohmann::json& node,
                                                          int depth) {
      node["x"] = depthX[depth];
      if (node["children"].empty()) {
        node["y"] = nextRow;
        nextRow += kNodeHeight + kRowGap;
        return;
      }
      for (nlohmann::json& child : node["children"]) {
        place(child, depth + 1);
      }
      const double firstY = node["children"].front().value("y", 0.0);
      const double lastY = node["children"].back().value("y", 0.0);
      node["y"] = (firstY + lastY) / 2.0;
    };
    place(root, 0);
    // Normalize: root centre at (0, 0).
    const double shiftX = root.value("x", 0.0) + root.value("width", 0.0) / 2.0;
    const double shiftY = root.value("y", 0.0) + kNodeHeight / 2.0;
    WalkTree(root, 0, [shiftX, shiftY](nlohmann::json& node, int) {
      node["x"] = node.value("x", 0.0) - shiftX;
      node["y"] = node.value("y", 0.0) - shiftY;
    });
  }

  /// Rings around the root; angular span proportional to leaf count,
  /// starting at the top (-90°) and sweeping clockwise.
  static void LayoutRadial(nlohmann::json& root) {
    WalkTree(root, 0, [](nlohmann::json& node, int) {
      node["width"] = NodeWidth(node);
      node["height"] = kNodeHeight;
    });
    const double kStartAngle = -3.14159265358979323846 / 2.0;
    const double kFullCircle = 2.0 * 3.14159265358979323846;
    const std::size_t totalLeaves = std::max<std::size_t>(1, LeafCount(root));

    std::function<void(nlohmann::json&, int, double, double)> place =
        [&](nlohmann::json& node, int depth, double start, double span) {
          const double angle = start + span / 2.0;
          const double radius = depth * kRingGap;
          const double cx = radius * std::cos(angle);
          const double cy = radius * std::sin(angle);
          node["x"] = cx - node.value("width", 0.0) / 2.0;
          node["y"] = cy - kNodeHeight / 2.0;
          if (node["children"].empty()) return;
          double childStart = start;
          for (nlohmann::json& child : node["children"]) {
            const double childSpan =
                span * static_cast<double>(LeafCount(child)) /
                static_cast<double>(std::max<std::size_t>(1, LeafCount(node)));
            place(child, depth + 1, childStart, childSpan);
            childStart += childSpan;
          }
        };
    place(root, 0, kStartAngle, kFullCircle);
    // Silence unused warning for totalLeaves (kept for clarity of invariants).
    (void)totalLeaves;
  }
};

}  // namespace

WB_REGISTER_DOMAIN(MindmapDomain)

}  // namespace wb
