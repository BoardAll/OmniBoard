// flowchart/flowchart.cpp — domain "flowchart" (task package 1.5).
// Owns: core/src/flowchart.
//
// Ops (《流程图模块设计》§3/§7/§8):
//   create       {pageId, element?}               -> flowchart container
//   addNode      {flowchartId, node}              -> {"node","nodeCount"}
//   removeNode   {flowchartId, nodeId}            -> {"nodeCount","connectorCount"}
//   connect      {flowchartId, from, to, label?}  -> {"connector","connectorCount"}
//   lockNode     {flowchartId, nodeId, locked?}   -> {"node","nodeId","locked"}
//   autoLayout   {flowchartId, options}           -> layered layout + polyline
//                                                    routing (spacing 80/60)
//   toSwimlane   {flowchartId, orientation}       -> lane rects from node groups
//   labelBranches{flowchartId}                    -> decision edges "是"/"否"
//   list         {pageId}
//
// Node types (§3.1): start end process decision inputOutput document database
// manualOperation connector annotation swimlane custom (case-insensitive).
// Coordinates live inside data.nodes[].{x,y,width,height}; connectors keep
// {waypoints,autoRoute} so the renderer can draw orthogonal polylines.

#include <algorithm>
#include <cmath>
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

constexpr double kDefaultNodeWidth = 160.0;
constexpr double kDefaultNodeHeight = 60.0;
constexpr double kHorizontalSpacing = 80.0;   // 同层节点间距
constexpr double kVerticalSpacing = 60.0;     // 层间距
constexpr double kLanePadding = 16.0;         // 泳道内边距

std::string ToLower(std::string value) {
  for (char& ch : value) {
    if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
  }
  return value;
}

/// Normalizes a node type string to the §3.1 canonical spelling.
std::string NormalizeType(const std::string& raw) {
  static const char* kTypes[] = {
      "start",     "end",        "process",        "decision",
      "inputoutput", "document",   "database",       "manualoperation",
      "connector", "annotation", "swimlane",       "custom"};
  const std::string lower = ToLower(raw);
  for (const char* type : kTypes) {
    if (lower == type) return type;
  }
  if (lower == "inputoutput" || lower == "input_output" || lower == "io") {
    return "inputoutput";
  }
  if (lower == "manualoperation" || lower == "manual_operation") {
    return "manualoperation";
  }
  return "process";
}

double NumberOr(const nlohmann::json& object, const char* key, double fallback) {
  if (object.contains(key) && object[key].is_number()) {
    return object[key].get<double>();
  }
  return fallback;
}

struct NodeBox {
  double x = 0.0;
  double y = 0.0;
  double w = kDefaultNodeWidth;
  double h = kDefaultNodeHeight;
};

NodeBox ReadBox(const nlohmann::json& node) {
  NodeBox box;
  box.x = NumberOr(node, "x", 0.0);
  box.y = NumberOr(node, "y", 0.0);
  box.w = NumberOr(node, "width", kDefaultNodeWidth);
  box.h = NumberOr(node, "height", kDefaultNodeHeight);
  if (box.w <= 0.0) box.w = kDefaultNodeWidth;
  if (box.h <= 0.0) box.h = kDefaultNodeHeight;
  return box;
}

void WriteBox(nlohmann::json& node, const NodeBox& box) {
  node["x"] = box.x;
  node["y"] = box.y;
  node["width"] = box.w;
  node["height"] = box.h;
}

/// Next "prefix-N" id: scans existing ids and returns max suffix + 1.
std::string NextId(const nlohmann::json& items, const char* prefix) {
  const std::string head = std::string(prefix) + "-";
  long long maxIndex = 0;
  for (const auto& item : items) {
    const std::string id = item.value("id", std::string());
    if (id.rfind(head, 0) == 0) {
      try {
        maxIndex = std::max(maxIndex, std::stoll(id.substr(head.size())));
      } catch (...) {
      }
    }
  }
  return head + std::to_string(maxIndex + 1);
}

class FlowchartDomain : public DomainHandler {
 public:
  std::string name() const override { return "flowchart"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "create") return Create(args);
    if (op == "addNode") return AddNode(args);
    if (op == "removeNode") return RemoveNode(args);
    if (op == "connect") return Connect(args);
    if (op == "lockNode") return LockNode(args);
    if (op == "autoLayout") return AutoLayout(args);
    if (op == "toSwimlane") return ToSwimlane(args);
    if (op == "labelBranches") return LabelBranches(args);
    if (op == "list") return List(args);
    return domainError("NotFound", "unknown flowchart op: " + op);
  }

 private:
  /// Finds a "flowchart" element; fills errorCode/errorMessage on failure.
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
    if (element.value("type", std::string()) != "flowchart") {
      *errorCode = "InvalidArgument";
      *errorMessage = "element is not a flowchart: " + elementId;
      return nullptr;
    }
    return &element;
  }

  static nlohmann::json DefaultData() {
    nlohmann::json data;
    data["nodes"] = nlohmann::json::array();
    data["connectors"] = nlohmann::json::array();
    data["swimlanes"] = nlohmann::json::array();
    data["direction"] = "topToBottom";
    data["templateId"] = "";
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
    element["type"] = "flowchart";

    nlohmann::json data = DefaultData();
    // Absorb top-level shorthand (nodes/connectors/...) into data.
    for (const char* key : {"nodes", "connectors", "swimlanes", "direction",
                            "templateId"}) {
      if (element.contains(key)) {
        data[key] = element[key];
        element.erase(key);
      }
    }
    if (element.contains("data") && element["data"].is_object()) {
      for (auto it = element["data"].begin(); it != element["data"].end(); ++it) {
        data[it.key()] = it.value();
      }
    }
    if (!data["nodes"].is_array()) data["nodes"] = nlohmann::json::array();
    if (!data["connectors"].is_array()) {
      data["connectors"] = nlohmann::json::array();
    }
    if (!data["swimlanes"].is_array()) {
      data["swimlanes"] = nlohmann::json::array();
    }
    // Normalize provided nodes.
    for (nlohmann::json& node : data["nodes"]) {
      if (!node.is_object()) node = nlohmann::json::object();
      if (node.value("id", std::string()).empty()) {
        node["id"] = NextId(data["nodes"], "node");
      }
      node["type"] = NormalizeType(node.value("type", std::string("process")));
      if (!node.contains("text")) node["text"] = "";
      NodeBox box = ReadBox(node);
      WriteBox(node, box);
      node["locked"] = node.value("locked", false);
      node["hidden"] = node.value("hidden", false);
    }
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
    result["type"] = "flowchart";
    return domainOk(result.dump());
  }

  std::string AddNode(const nlohmann::json& args) {
    const std::string flowchartId = args.value("flowchartId", std::string());
    if (!args.contains("node") || !args["node"].is_object()) {
      return domainError("InvalidArgument", "args.node is required");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), flowchartId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& nodes = (*element)["data"]["nodes"];
    nlohmann::json node = args["node"];
    if (node.value("id", std::string()).empty()) {
      node["id"] = NextId(nodes, "node");
    } else {
      const std::string requestedId = node["id"].get<std::string>();
      for (const nlohmann::json& existing : nodes) {
        if (existing.value("id", std::string()) == requestedId) {
          return domainError("Conflict", "node already exists: " + requestedId);
        }
      }
    }
    node["type"] = NormalizeType(node.value("type", std::string("process")));
    if (!node.contains("text")) node["text"] = "";
    NodeBox box = ReadBox(node);
    WriteBox(node, box);
    node["locked"] = node.value("locked", false);
    node["hidden"] = node.value("hidden", false);
    node["incoming"] = node.value("incoming", nlohmann::json::array());
    node["outgoing"] = node.value("outgoing", nlohmann::json::array());
    nodes.push_back(std::move(node));
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["node"] = nodes.back();
    result["nodeCount"] = static_cast<int>(nodes.size());
    result["flowchartId"] = flowchartId;
    return domainOk(result.dump());
  }

  std::string RemoveNode(const nlohmann::json& args) {
    const std::string flowchartId = args.value("flowchartId", std::string());
    const std::string nodeId = args.value("nodeId", std::string());
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), flowchartId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& nodes = (*element)["data"]["nodes"];
    const std::size_t before = nodes.size();
    nodes.erase(std::remove_if(nodes.begin(), nodes.end(),
                               [&nodeId](const nlohmann::json& node) {
                                 return node.value("id", std::string()) == nodeId;
                               }),
                nodes.end());
    if (nodes.size() == before) {
      return domainError("NotFound", "unknown node: " + nodeId);
    }
    nlohmann::json& connectors = (*element)["data"]["connectors"];
    std::vector<std::string> removedEdges;
    for (const nlohmann::json& connector : connectors) {
      if (connector.value("from", std::string()) == nodeId ||
          connector.value("to", std::string()) == nodeId) {
        removedEdges.push_back(connector.value("id", std::string()));
      }
    }
    connectors.erase(
        std::remove_if(connectors.begin(), connectors.end(),
                       [&nodeId](const nlohmann::json& connector) {
                         return connector.value("from", std::string()) ==
                                    nodeId ||
                                connector.value("to", std::string()) == nodeId;
                       }),
        connectors.end());
    for (nlohmann::json& node : nodes) {
      for (const char* key : {"incoming", "outgoing"}) {
        nlohmann::json& edges = node[key];
        if (!edges.is_array()) continue;
        edges.erase(std::remove_if(edges.begin(), edges.end(),
                                   [&removedEdges](const nlohmann::json& id) {
                                     const std::string value =
                                         id.is_string() ? id.get<std::string>()
                                                        : std::string();
                                     return std::find(removedEdges.begin(),
                                                      removedEdges.end(),
                                                      value) !=
                                            removedEdges.end();
                                   }),
                    edges.end());
      }
    }
    (*element)["updatedAt"] = timeMillis();
    nlohmann::json result;
    result["flowchartId"] = flowchartId;
    result["nodeCount"] = static_cast<int>(nodes.size());
    result["connectorCount"] = static_cast<int>(connectors.size());
    return domainOk(result.dump());
  }

  std::string Connect(const nlohmann::json& args) {
    const std::string flowchartId = args.value("flowchartId", std::string());
    const std::string from = args.value("from", std::string());
    const std::string to = args.value("to", std::string());
    if (from.empty() || to.empty()) {
      return domainError("InvalidArgument", "args.from and args.to are required");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), flowchartId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& nodes = (*element)["data"]["nodes"];
    nlohmann::json* fromNode = nullptr;
    nlohmann::json* toNode = nullptr;
    for (nlohmann::json& node : nodes) {
      const std::string id = node.value("id", std::string());
      if (id == from) fromNode = &node;
      if (id == to) toNode = &node;
    }
    if (fromNode == nullptr) {
      return domainError("NotFound", "unknown node: " + from);
    }
    if (toNode == nullptr) {
      return domainError("NotFound", "unknown node: " + to);
    }

    nlohmann::json& connectors = (*element)["data"]["connectors"];
    nlohmann::json connector;
    connector["id"] = args.value("id", NextId(connectors, "edge"));
    for (const nlohmann::json& existing : connectors) {
      if (existing.value("id", std::string()) ==
          connector["id"].get<std::string>()) {
        return domainError("Conflict",
                           "connector already exists: " +
                               connector["id"].get<std::string>());
      }
    }
    connector["from"] = from;
    connector["to"] = to;
    connector["label"] = args.value("label", std::string());
    connector["style"] = args.value("style", std::string("polyline"));
    connector["arrowStart"] = false;
    connector["arrowEnd"] = true;
    connector["autoRoute"] = true;
    connector["waypoints"] = nlohmann::json::array();
    connectors.push_back(std::move(connector));

    if (!(*fromNode).contains("outgoing") || !(*fromNode)["outgoing"].is_array()) {
      (*fromNode)["outgoing"] = nlohmann::json::array();
    }
    if (!(*toNode).contains("incoming") || !(*toNode)["incoming"].is_array()) {
      (*toNode)["incoming"] = nlohmann::json::array();
    }
    (*fromNode)["outgoing"].push_back(connectors.back()["id"]);
    (*toNode)["incoming"].push_back(connectors.back()["id"]);
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["connector"] = connectors.back();
    result["connectorCount"] = static_cast<int>(connectors.size());
    result["flowchartId"] = flowchartId;
    return domainOk(result.dump());
  }

  std::string LockNode(const nlohmann::json& args) {
    const std::string flowchartId = args.value("flowchartId", std::string());
    const std::string nodeId = args.value("nodeId", std::string());
    const bool locked = args.value("locked", true);
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), flowchartId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& nodes = (*element)["data"]["nodes"];
    for (nlohmann::json& node : nodes) {
      if (node.value("id", std::string()) == nodeId) {
        node["locked"] = locked;
        (*element)["updatedAt"] = timeMillis();
        nlohmann::json result;
        result["node"] = node;
        result["nodeId"] = nodeId;
        result["locked"] = locked;
        return domainOk(result.dump());
      }
    }
    return domainError("NotFound", "unknown node: " + nodeId);
  }

  std::string AutoLayout(const nlohmann::json& args) {
    const std::string flowchartId = args.value("flowchartId", std::string());
    nlohmann::json options = args.value("options", nlohmann::json::object());
    if (!options.is_object()) options = nlohmann::json::object();
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), flowchartId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& data = (*element)["data"];
    nlohmann::json& nodes = data["nodes"];
    nlohmann::json& connectors = data["connectors"];

    std::string direction =
        options.value("direction", data.value("direction", std::string("topToBottom")));
    if (direction != "leftToRight" && direction != "topToBottom") {
      return domainError("InvalidArgument", "unknown layout direction: " + direction);
    }
    const double hSpacing =
        std::max(0.0, options.value("horizontalSpacing",
                                    options.value("hSpacing", kHorizontalSpacing)));
    const double vSpacing =
        std::max(0.0, options.value("verticalSpacing",
                                    options.value("vSpacing", kVerticalSpacing)));
    std::string align = options.value("align", std::string("center"));
    if (align != "left" && align != "center" && align != "right") {
      return domainError("InvalidArgument", "unknown align: " + align);
    }

    const std::size_t count = nodes.size();
    if (count == 0) {
      nlohmann::json result;
      result["flowchartId"] = flowchartId;
      result["direction"] = direction;
      result["nodeCount"] = 0;
      result["nodes"] = nlohmann::json::array();
      return domainOk(result.dump());
    }

    // Index nodes by id.
    std::map<std::string, std::size_t> indexById;
    for (std::size_t i = 0; i < count; ++i) {
      indexById[nodes[i].value("id", std::string())] = i;
    }

    // Longest-path layering (Bellman-Ford style, bounded by node count).
    std::vector<int> layer(count, 0);
    for (std::size_t pass = 0; pass < count; ++pass) {
      bool changed = false;
      for (const nlohmann::json& connector : connectors) {
        auto fromIt = indexById.find(connector.value("from", std::string()));
        auto toIt = indexById.find(connector.value("to", std::string()));
        if (fromIt == indexById.end() || toIt == indexById.end()) continue;
        if (layer[toIt->second] < layer[fromIt->second] + 1) {
          layer[toIt->second] = layer[fromIt->second] + 1;
          changed = true;
        }
      }
      if (!changed) break;
    }

    // Group nodes by layer, preserving input order.
    std::map<int, std::vector<std::size_t>> layers;
    for (std::size_t i = 0; i < count; ++i) {
      layers[layer[i]].push_back(i);
    }

    // Position nodes layer by layer.
    double cursor = 0.0;
    for (auto& [layerIndex, members] : layers) {
      (void)layerIndex;
      double extent = 0.0;
      double span = 0.0;
      for (std::size_t i = 0; i < members.size(); ++i) {
        const NodeBox box = ReadBox(nodes[members[i]]);
        extent = std::max(extent, direction == "topToBottom" ? box.h : box.w);
        span += direction == "topToBottom" ? box.w : box.h;
        if (i + 1 < members.size()) {
          span += hSpacing;  // 同层节点间距
        }
      }
      double axisStart = 0.0;
      if (align == "center") axisStart = -span / 2.0;
      else if (align == "right") axisStart = -span;
      double axisCursor = axisStart;
      for (std::size_t member : members) {
        nlohmann::json& node = nodes[member];
        NodeBox box = ReadBox(node);
        if (!node.value("locked", false)) {
          if (direction == "topToBottom") {
            box.x = axisCursor;
            box.y = cursor + (extent - box.h) / 2.0;
            axisCursor += box.w + hSpacing;
          } else {
            box.y = axisCursor;
            box.x = cursor + (extent - box.w) / 2.0;
            axisCursor += box.h + hSpacing;
          }
          WriteBox(node, box);
        } else {
          axisCursor += (direction == "topToBottom" ? box.w : box.h) + hSpacing;
        }
      }
      cursor += extent + vSpacing;  // 层间距
    }
    data["direction"] = direction;

    // Orthogonal polyline routing for auto-routed connectors.
    auto findBox = [&nodes, &indexById](const std::string& id,
                                        NodeBox* out) -> bool {
      auto it = indexById.find(id);
      if (it == indexById.end()) return false;
      *out = ReadBox(nodes[it->second]);
      return true;
    };
    for (nlohmann::json& connector : connectors) {
      if (!connector.value("autoRoute", true)) continue;
      const std::string style = connector.value("style", std::string("polyline"));
      if (style == "straight" || style == "curve") {
        connector["waypoints"] = nlohmann::json::array();
        continue;
      }
      NodeBox fromBox;
      NodeBox toBox;
      if (!findBox(connector.value("from", std::string()), &fromBox) ||
          !findBox(connector.value("to", std::string()), &toBox)) {
        continue;
      }
      nlohmann::json waypoints = nlohmann::json::array();
      auto point = [](double x, double y) {
        nlohmann::json p;
        p["x"] = x;
        p["y"] = y;
        return p;
      };
      if (direction == "topToBottom") {
        const double sx = fromBox.x + fromBox.w / 2.0;
        const double sy = fromBox.y + fromBox.h;
        const double tx = toBox.x + toBox.w / 2.0;
        const double ty = toBox.y;
        const double midY = (sy + ty) / 2.0;
        waypoints.push_back(point(sx, sy));
        waypoints.push_back(point(sx, midY));
        waypoints.push_back(point(tx, midY));
        waypoints.push_back(point(tx, ty));
      } else {
        const double sx = fromBox.x + fromBox.w;
        const double sy = fromBox.y + fromBox.h / 2.0;
        const double tx = toBox.x;
        const double ty = toBox.y + toBox.h / 2.0;
        const double midX = (sx + tx) / 2.0;
        waypoints.push_back(point(sx, sy));
        waypoints.push_back(point(midX, sy));
        waypoints.push_back(point(midX, ty));
        waypoints.push_back(point(tx, ty));
      }
      connector["waypoints"] = std::move(waypoints);
    }
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["flowchartId"] = flowchartId;
    result["direction"] = direction;
    result["nodeCount"] = static_cast<int>(count);
    result["nodes"] = nodes;
    result["connectors"] = connectors;
    result["connectorCount"] = static_cast<int>(connectors.size());
    return domainOk(result.dump());
  }

  std::string ToSwimlane(const nlohmann::json& args) {
    const std::string flowchartId = args.value("flowchartId", std::string());
    std::string orientation = "horizontal";
    if (args.contains("orientation")) {
      const nlohmann::json& raw = args["orientation"];
      if (raw.is_number_integer()) {
        orientation = raw.get<int>() == 1 ? "vertical" : "horizontal";
      } else if (raw.is_string()) {
        const std::string text = ToLower(raw.get<std::string>());
        orientation = text == "vertical" ? "vertical" : "horizontal";
      }
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), flowchartId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& data = (*element)["data"];
    nlohmann::json& nodes = data["nodes"];
    nlohmann::json& existingLanes = data["swimlanes"];

    // Group nodes by swimlaneId (in order of first appearance); empty ids
    // share the first lane so a plain flowchart converts into one lane.
    bool anyGrouped = false;
    for (const nlohmann::json& node : nodes) {
      if (!node.value("swimlaneId", std::string()).empty()) {
        anyGrouped = true;
        break;
      }
    }
    std::vector<std::string> groupOrder;
    std::map<std::string, std::vector<std::size_t>> groups;
    for (std::size_t i = 0; i < nodes.size(); ++i) {
      std::string key;
      if (anyGrouped) {
        key = nodes[i].value("swimlaneId", std::string());
        if (key.empty()) key = "default";
      } else {
        key = "lane-1";
      }
      if (groups.find(key) == groups.end()) groupOrder.push_back(key);
      groups[key].push_back(i);
    }

    auto laneName = [&existingLanes](const std::string& id) {
      for (const nlohmann::json& lane : existingLanes) {
        if (lane.value("id", std::string()) == id) {
          return lane.value("name", std::string());
        }
      }
      return std::string();
    };

    nlohmann::json lanes = nlohmann::json::array();
    int laneIndex = 0;
    for (const std::string& key : groupOrder) {
      ++laneIndex;
      nlohmann::json lane;
      lane["id"] = key == "default" ? "lane-" + std::to_string(laneIndex) : key;
      std::string name = laneName(lane["id"].get<std::string>());
      if (name.empty()) name = "泳道 " + std::to_string(laneIndex);
      lane["name"] = name;
      lane["orientation"] = orientation;
      // Bounding box of members expanded by the lane padding.
      double minX = 0.0;
      double minY = 0.0;
      double maxX = 0.0;
      double maxY = 0.0;
      bool first = true;
      for (std::size_t member : groups[key]) {
        const NodeBox box = ReadBox(nodes[member]);
        if (first) {
          minX = box.x;
          minY = box.y;
          maxX = box.x + box.w;
          maxY = box.y + box.h;
          first = false;
        } else {
          minX = std::min(minX, box.x);
          minY = std::min(minY, box.y);
          maxX = std::max(maxX, box.x + box.w);
          maxY = std::max(maxY, box.y + box.h);
        }
        nodes[member]["swimlaneId"] = lane["id"];
      }
      if (first) {
        minX = minY = 0.0;
        maxX = maxY = 0.0;
      }
      lane["position"] =
          nlohmann::json{{"x", minX - kLanePadding}, {"y", minY - kLanePadding}};
      lane["size"] = nlohmann::json{{"width", (maxX - minX) + 2 * kLanePadding},
                                    {"height", (maxY - minY) + 2 * kLanePadding}};
      lane["nodeCount"] = static_cast<int>(groups[key].size());
      lanes.push_back(std::move(lane));
    }
    data["swimlanes"] = lanes;
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["flowchartId"] = flowchartId;
    result["orientation"] = orientation;
    result["laneCount"] = static_cast<int>(lanes.size());
    result["lanes"] = lanes;
    return domainOk(result.dump());
  }

  std::string LabelBranches(const nlohmann::json& args) {
    const std::string flowchartId = args.value("flowchartId", std::string());
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), flowchartId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& nodes = (*element)["data"]["nodes"];
    nlohmann::json& connectors = (*element)["data"]["connectors"];
    int labeled = 0;
    int decisionCount = 0;
    nlohmann::json decisions = nlohmann::json::array();
    for (nlohmann::json& node : nodes) {
      if (node.value("type", std::string()) != "decision") continue;
      ++decisionCount;
      std::vector<nlohmann::json*> outgoing;
      for (nlohmann::json& connector : connectors) {
        if (connector.value("from", std::string()) ==
            node.value("id", std::string())) {
          outgoing.push_back(&connector);
        }
      }
      if (outgoing.size() >= 2) {
        static const char* kLabels[] = {"是", "否"};
        for (std::size_t i = 0; i < 2; ++i) {
          if (outgoing[i]->value("label", std::string()).empty()) {
            (*outgoing[i])["label"] = kLabels[i];
            ++labeled;
          }
        }
      }
      decisions.push_back(node.value("id", std::string()));
    }
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["flowchartId"] = flowchartId;
    result["labeled"] = labeled;
    result["decisionCount"] = decisionCount;
    result["decisions"] = std::move(decisions);
    result["connectors"] = connectors;
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
      if (element.value("type", std::string()) != "flowchart") continue;
      nlohmann::json summary = SceneStore::elementSummary(element);
      int nodeCount = 0;
      int connectorCount = 0;
      int laneCount = 0;
      if (element.contains("data") && element["data"].is_object()) {
        const nlohmann::json& data = element["data"];
        if (data.contains("nodes") && data["nodes"].is_array()) {
          nodeCount = static_cast<int>(data["nodes"].size());
        }
        if (data.contains("connectors") && data["connectors"].is_array()) {
          connectorCount = static_cast<int>(data["connectors"].size());
        }
        if (data.contains("swimlanes") && data["swimlanes"].is_array()) {
          laneCount = static_cast<int>(data["swimlanes"].size());
        }
      }
      summary["nodeCount"] = nodeCount;
      summary["connectorCount"] = connectorCount;
      summary["laneCount"] = laneCount;
      elements.push_back(std::move(summary));
    }
    nlohmann::json result;
    result["elements"] = std::move(elements);
    result["count"] = static_cast<int>(result["elements"].size());
    return domainOk(result.dump());
  }
};

}  // namespace

WB_REGISTER_DOMAIN(FlowchartDomain)

}  // namespace wb
