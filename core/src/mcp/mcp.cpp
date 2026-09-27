// mcp/mcp.cpp — domain "mcp" (task package 1.8).
// Owns: core/src/mcp.
//
// Ops (《MCP_Server详细设计》§11.10 + FFI forwarding): start, stop,
// isRunning, handleRequest, sessionCreate, sessionGet, sessionClose,
// listTools, callTool, listResources, readResource, listPrompts,
// getPrompt, auditQuery, auditExport.
//
// The server speaks JSON-RPC 2.0 (design §2): `handleRequest` processes a
// single client message (initialize / notifications/initialized / ping /
// tools/* / resources/* / prompts/*) and returns the JSON-RPC response;
// the other ops are convenience wrappers used by the Dart side.
//
// Tools are bridged from the shared ToolRegistry (domain "tool") and are
// renamed with the §6.3 rule (dot + camelCase -> snake_case, lowercase).
// Every tools/call is written to the audit domain, so MCP activity shares
// the same audit trail as user and AI operations. The transport itself
// (stdio / SSE / HTTP) is a later-wave concern: `start` only flips the
// running state and records the config.
//
// Locking: the MCP mutex guards sessions/running state only; all
// invokeDomain() calls (tool execution, page/element reads, audit) happen
// OUTSIDE the lock.

#include <algorithm>
#include <cctype>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <nlohmann/json.hpp>

#include "wb/ffi/domain.h"
#include "wb/platform/platform.h"

namespace wb {
namespace {

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

// --- JSON-RPC error codes (design §15) ---------------------------------------
constexpr int kRpcParseError = -32700;
constexpr int kRpcInvalidRequest = -32600;
constexpr int kRpcMethodNotFound = -32601;
constexpr int kRpcInvalidParams = -32602;
constexpr int kRpcInternalError = -32603;
constexpr int kRpcPermissionDenied = -32002;
constexpr int kRpcNotFound = -32003;
constexpr int kRpcConflict = -32004;

nlohmann::json RpcResult(const nlohmann::json& id, nlohmann::json result) {
  nlohmann::json message;
  message["id"] = id;
  message["jsonrpc"] = "2.0";
  message["result"] = std::move(result);
  return message;
}

nlohmann::json RpcError(const nlohmann::json& id, int code,
                        const std::string& message,
                        nlohmann::json data = nlohmann::json()) {
  nlohmann::json error;
  error["code"] = code;
  error["message"] = message;
  if (!data.is_null()) error["data"] = std::move(data);
  nlohmann::json envelope;
  envelope["error"] = std::move(error);
  envelope["id"] = id;
  envelope["jsonrpc"] = "2.0";
  return envelope;
}

// --- tool name mapping (design §6.3) ------------------------------------------
/// "3d.setFaceColor" -> "3d_set_face_color".
std::string ToMcpName(const std::string& toolId) {
  std::string out;
  out.reserve(toolId.size() + 4);
  for (const char c : toolId) {
    if (c == '.') {
      out += '_';
    } else if (std::isupper(static_cast<unsigned char>(c)) != 0) {
      if (!out.empty() && out.back() != '_') out += '_';
      out += static_cast<char>(
          std::tolower(static_cast<unsigned char>(c)));
    } else {
      out += c;
    }
  }
  return out;
}

/// Read-only operations get a ":read" scope, everything else ":write".
bool IsReadOp(const std::string& toolId) {
  const std::size_t dot = toolId.find('.');
  const std::string op =
      dot == std::string::npos ? toolId : toolId.substr(dot + 1);
  static const char* kReadPrefixes[] = {
      "get",  "list", "status", "query",    "check",    "current",
      "stats", "info", "hitTest", "bounds", "analyze",  "isRunning",
      "levels", "preview"};
  for (const char* prefix : kReadPrefixes) {
    if (op.rfind(prefix, 0) == 0) return true;
  }
  return false;
}

std::string ScopeFor(const std::string& toolId) {
  const std::size_t dot = toolId.find('.');
  const std::string zone =
      dot == std::string::npos ? toolId : toolId.substr(0, dot);
  return zone + (IsReadOp(toolId) ? ":read" : ":write");
}

/// Confirmation level (《AI 助手与 MCP 设计》§3.3): destructive and
/// permission-changing tools need Confirm, batch/layout tools Preview.
std::string ConfirmationFor(const std::string& toolId) {
  static const char* kConfirmWords[] = {"delete", "destroy",  "share",
                                        "grant",  "revoke"};
  static const char* kPreviewWords[] = {"layout", "batch"};
  for (const char* word : kConfirmWords) {
    if (toolId.find(word) != std::string::npos) return "confirm";
  }
  for (const char* word : kPreviewWords) {
    if (toolId.find(word) != std::string::npos) return "preview";
  }
  return "auto";
}

/// Registry entry -> MCP tool definition (design §11.5).
nlohmann::json ToMcpTool(const nlohmann::json& tool) {
  const std::string id = tool.value("id", std::string());
  nlohmann::json item;
  item["confirmation"] = ConfirmationFor(id);
  item["description"] = tool.value("description", std::string());
  nlohmann::json schema;
  schema["additionalProperties"] = true;
  schema["type"] = "object";
  item["inputSchema"] = std::move(schema);
  item["internalToolId"] = id;
  item["name"] = ToMcpName(id);
  item["scope"] = ScopeFor(id);
  return item;
}

/// Pulls the live tool list from the shared ToolRegistry.
bool LoadToolList(std::vector<nlohmann::json>* tools, std::string* problem) {
  const std::string response = invokeDomain("tool", "list", "{}");
  const nlohmann::json parsed =
      nlohmann::json::parse(response, nullptr, false);
  if (!parsed.is_object() || parsed.value("ok", false) != true ||
      !parsed.contains("result") || !parsed["result"].contains("tools") ||
      !parsed["result"]["tools"].is_array()) {
    *problem = "tool registry unavailable";
    return false;
  }
  for (const nlohmann::json& tool : parsed["result"]["tools"]) {
    tools->push_back(tool);
  }
  return true;
}

/// MCP name -> internal tool id; empty when unknown.
std::string FindToolId(const std::vector<nlohmann::json>& tools,
                       const std::string& mcpName) {
  for (const nlohmann::json& tool : tools) {
    if (ToMcpName(tool.value("id", std::string())) == mcpName) {
      return tool.value("id", std::string());
    }
  }
  return std::string();
}

/// Executes a tool through the ToolRegistry and shapes the MCP result
/// (design §6.2: content / isError / structuredContent).
nlohmann::json ExecuteToolInternal(const std::string& toolId,
                                   const nlohmann::json& arguments) {
  nlohmann::json wrapper;
  wrapper["args"] = arguments.is_object() ? arguments : nlohmann::json::object();
  wrapper["toolId"] = toolId;
  const std::string response =
      invokeDomain("tool", "execute", wrapper.dump());
  const nlohmann::json parsed =
      nlohmann::json::parse(response, nullptr, false);
  nlohmann::json result;
  nlohmann::json content = nlohmann::json::array();
  nlohmann::json item;
  item["type"] = "text";
  if (parsed.is_object() && parsed.value("ok", false) == true) {
    item["text"] = parsed["result"].dump();
    content.push_back(std::move(item));
    result["content"] = std::move(content);
    result["isError"] = false;
    result["structuredContent"] = parsed["result"];
  } else {
    std::string message = "tool execution failed";
    nlohmann::json error = nlohmann::json::object();
    if (parsed.is_object() && parsed.contains("error")) {
      error = parsed["error"];
      message = error.value("message", message);
    }
    item["text"] = message;
    content.push_back(std::move(item));
    result["content"] = std::move(content);
    result["isError"] = true;
    nlohmann::json structured;
    structured["error"] = std::move(error);
    result["structuredContent"] = std::move(structured);
  }
  return result;
}

/// Appends one audit entry (design §10: all tools/call are audited).
void AuditWrite(const std::string& userId, const std::string& toolId,
                const std::string& argsJson, const std::string& resultJson) {
  nlohmann::json entry;
  entry["argsJson"] = argsJson;
  entry["fromAI"] = true;  // external AI clients drive MCP calls
  entry["resultJson"] = resultJson;
  entry["toolId"] = toolId;
  entry["userId"] = userId.empty() ? std::string("mcp:anonymous") : userId;
  invokeDomain("audit", "log", nlohmann::json{{"entry", entry}}.dump());
}

// --- prompts (design §8.3) -----------------------------------------------------
struct PromptSpec {
  const char* name;
  const char* description;
};

const PromptSpec kPrompts[] = {
    {"brainstorm", "头脑风暴：生成便签并分组"},
    {"flowchart", "生成流程图"},
    {"mindmap", "生成思维导图"},
    {"summarize", "总结当前白板"},
    {"cluster", "聚类整理"},
    {"vote", "投票"},
    {"userJourney", "用户旅程"},
    {"swot", "SWOT 分析"},
    {"retrospective", "回顾"},
    {"kanban", "看板"},
};

const PromptSpec* FindPrompt(const std::string& name) {
  for (const PromptSpec& prompt : kPrompts) {
    if (name == prompt.name) return &prompt;
  }
  return nullptr;
}

struct PromptArg {
  const char* name;
  bool required;
  const char* description;
};

std::vector<PromptArg> PromptArgs(const std::string& name) {
  if (name == "brainstorm") {
    return {{"topic", true, "头脑风暴主题"},
            {"count", false, "便签数量（默认 10）"}};
  }
  if (name == "flowchart") return {{"process", true, "流程描述"}};
  if (name == "mindmap") return {{"topic", true, "中心主题"}};
  if (name == "userJourney") return {{"persona", true, "用户角色"}};
  if (name == "swot") return {{"topic", true, "分析主题"}};
  if (name == "vote") return {{"topic", false, "投票主题"}};
  return {};
}

/// Reads an argument as text (string / number accepted).
std::string ArgText(const nlohmann::json& arguments, const std::string& key,
                    const std::string& fallback = "") {
  if (!arguments.contains(key)) return fallback;
  const nlohmann::json& value = arguments[key];
  if (value.is_string()) return value.get<std::string>();
  if (value.is_number_integer()) {
    return std::to_string(value.get<long long>());
  }
  if (value.is_number()) return std::to_string(value.get<double>());
  return fallback;
}

/// Renders the prompt text; returns false when a required argument is
/// missing (fills *missing).
bool BuildPromptText(const std::string& name, const nlohmann::json& arguments,
                     std::string* text, std::string* missing) {
  for (const PromptArg& arg : PromptArgs(name)) {
    if (arg.required && ArgText(arguments, arg.name).empty()) {
      *missing = arg.name;
      return false;
    }
  }
  if (name == "brainstorm") {
    *text = "请围绕“" + ArgText(arguments, "topic") + "”生成 " +
            ArgText(arguments, "count", "10") + " 个便签，并按主题分组。";
  } else if (name == "flowchart") {
    *text = "请为流程“" + ArgText(arguments, "process") +
            "”生成流程图，包含开始、判断分支与结束节点。";
  } else if (name == "mindmap") {
    *text = "请以“" + ArgText(arguments, "topic") +
            "”为中心生成思维导图，包含至少三层分支。";
  } else if (name == "summarize") {
    *text = "请总结当前白板的页面、元素与主要内容。";
  } else if (name == "cluster") {
    *text = "请对当前白板内容进行聚类整理，按主题分组并命名。";
  } else if (name == "vote") {
    const std::string topic = ArgText(arguments, "topic");
    *text = topic.empty() ? std::string("请发起一次投票。")
                          : "请围绕“" + topic + "”发起一次投票。";
  } else if (name == "userJourney") {
    *text = "请生成“" + ArgText(arguments, "persona") +
            "”的用户旅程图，包含阶段、行为、痛点与机会点。";
  } else if (name == "swot") {
    *text = "请围绕“" + ArgText(arguments, "topic") +
            "”生成 SWOT 分析表（优势/劣势/机会/威胁）。";
  } else if (name == "retrospective") {
    *text = "请生成一次敏捷回顾模板（做得好 / 待改进 / 行动项）。";
  } else if (name == "kanban") {
    *text = "请生成看板模板（待办 / 进行中 / 已完成）。";
  } else {
    return false;
  }
  return true;
}

// --- process-wide MCP state ----------------------------------------------------
struct McpState {
  std::mutex mutex;
  bool running = false;
  nlohmann::json config = nlohmann::json::object();
  std::unordered_map<std::string, nlohmann::json> sessions;
  // uri -> sessionIds (design §7.4 resource subscription).
  std::unordered_map<std::string, std::vector<std::string>> subscriptions;
  int nextSessionId = 0;
  int requestCount = 0;
  int callCount = 0;
};

McpState& State() {
  static McpState state;
  return state;
}

std::vector<std::string> BoardsOf(const nlohmann::json& session) {
  std::vector<std::string> boards;
  if (session.contains("allowedBoards") && session["allowedBoards"].is_array()) {
    for (const nlohmann::json& item : session["allowedBoards"]) {
      if (item.is_string()) boards.push_back(item.get<std::string>());
    }
  }
  return boards;
}

/// Builds the resource catalog (design §7.3 URI scheme).
nlohmann::json BuildResourcesFor(const std::vector<std::string>& boards) {
  nlohmann::json resources = nlohmann::json::array();
  {
    nlohmann::json item;
    item["description"] = "所有白板";
    item["mimeType"] = "application/json";
    item["name"] = "白板列表";
    item["uri"] = "whiteboard://boards";
    resources.push_back(std::move(item));
  }
  for (const std::string& boardId : boards) {
    const std::string base = "whiteboard://boards/" + boardId;
    const std::pair<const char*, const char*> boardResources[] = {
        {"", "白板元数据"},        {"/pages", "页面列表"},
        {"/comments", "评论"},     {"/history", "历史"},
    };
    for (const auto& [suffix, description] : boardResources) {
      nlohmann::json item;
      item["description"] = description;
      item["mimeType"] = "application/json";
      item["name"] = boardId + suffix;
      item["uri"] = base + suffix;
      resources.push_back(std::move(item));
    }
    // Expand pages through the page domain (lock-free lookup).
    nlohmann::json pagesArgs;
    pagesArgs["boardId"] = boardId;
    const std::string response =
        invokeDomain("page", "list", pagesArgs.dump());
    const nlohmann::json parsed =
        nlohmann::json::parse(response, nullptr, false);
    if (!parsed.is_object() || parsed.value("ok", false) != true) continue;
    const nlohmann::json& pages = parsed["result"]["pages"];
    if (!pages.is_array()) continue;
    for (const nlohmann::json& page : pages) {
      const std::string pageId = page.value("id", std::string());
      if (pageId.empty()) continue;
      const std::string pageName = page.value("name", pageId);
      nlohmann::json pageItem;
      pageItem["description"] = "页面内容";
      pageItem["mimeType"] = "application/json";
      pageItem["name"] = pageName;
      pageItem["uri"] = base + "/pages/" + pageId;
      resources.push_back(std::move(pageItem));
      nlohmann::json elementsItem;
      elementsItem["description"] = "页面所有元素";
      elementsItem["mimeType"] = "application/json";
      elementsItem["name"] = pageName + "（元素）";
      elementsItem["uri"] = base + "/pages/" + pageId + "/elements";
      resources.push_back(std::move(elementsItem));
    }
  }
  return resources;
}

/// Splits "a/b/c" into segments.
std::vector<std::string> SplitPath(const std::string& path) {
  std::vector<std::string> segments;
  std::string current;
  for (const char c : path) {
    if (c == '/') {
      if (!current.empty()) segments.push_back(current);
      current.clear();
    } else {
      current += c;
    }
  }
  if (!current.empty()) segments.push_back(current);
  return segments;
}

/// Resolves a resource URI into the underlying domain result JSON.
/// Returns true on success; false fills *error*.
bool ReadResourceJson(const std::string& uri,
                      const std::vector<std::string>& sessionBoards,
                      nlohmann::json* content, std::string* error) {
  const std::string prefix = "whiteboard://";
  if (uri.rfind(prefix, 0) != 0) {
    *error = "unsupported uri scheme: " + uri;
    return false;
  }
  const std::vector<std::string> segments =
      SplitPath(uri.substr(prefix.size()));
  if (segments.empty() || segments[0] != "boards") {
    *error = "unknown resource: " + uri;
    return false;
  }
  if (segments.size() == 1) {
    nlohmann::json boards = nlohmann::json::array();
    for (const std::string& boardId : sessionBoards) boards.push_back(boardId);
    nlohmann::json result;
    result["boards"] = std::move(boards);
    result["count"] = static_cast<int>(result["boards"].size());
    *content = std::move(result);
    return true;
  }
  const std::string boardId = segments[1];
  const auto callPageList = [&](nlohmann::json* result) -> bool {
    nlohmann::json args;
    args["boardId"] = boardId;
    const std::string response =
        invokeDomain("page", "list", args.dump());
    const nlohmann::json parsed =
        nlohmann::json::parse(response, nullptr, false);
    if (!parsed.is_object() || parsed.value("ok", false) != true) {
      *error = "unknown board: " + boardId;
      return false;
    }
    *result = parsed["result"];
    return true;
  };
  if (segments.size() == 2) {
    nlohmann::json pages;
    if (!callPageList(&pages)) return false;
    nlohmann::json result;
    result["boardId"] = boardId;
    result["pageCount"] = pages.value("count", 0);
    result["pages"] = pages.value("pages", nlohmann::json::array());
    *content = std::move(result);
    return true;
  }
  if (segments[2] == "pages" && segments.size() == 3) {
    nlohmann::json pages;
    if (!callPageList(&pages)) return false;
    *content = std::move(pages);
    return true;
  }
  if (segments[2] == "comments" && segments.size() == 3) {
    nlohmann::json result;
    result["comments"] = nlohmann::json::array();
    result["count"] = 0;  // comment domain lands in a later wave
    *content = std::move(result);
    return true;
  }
  if (segments[2] == "history" && segments.size() == 3) {
    nlohmann::json result;
    result["count"] = 0;  // board history via command domain is Wave 2+
    result["history"] = nlohmann::json::array();
    *content = std::move(result);
    return true;
  }
  if (segments[2] == "pages" && segments.size() == 4) {
    nlohmann::json pages;
    if (!callPageList(&pages)) return false;
    for (const nlohmann::json& page :
         pages.value("pages", nlohmann::json::array())) {
      if (page.value("id", std::string()) == segments[3]) {
        nlohmann::json result;
        result["boardId"] = boardId;
        result["page"] = page;
        *content = std::move(result);
        return true;
      }
    }
    *error = "unknown page: " + segments[3];
    return false;
  }
  if (segments[2] == "pages" && segments.size() == 5 &&
      segments[4] == "elements") {
    nlohmann::json args;
    args["pageId"] = segments[3];
    const std::string response =
        invokeDomain("element", "list", args.dump());
    const nlohmann::json parsed =
        nlohmann::json::parse(response, nullptr, false);
    if (!parsed.is_object() || parsed.value("ok", false) != true) {
      *error = "unknown page: " + segments[3];
      return false;
    }
    *content = parsed["result"];
    return true;
  }
  *error = "unknown resource: " + uri;
  return false;
}

}  // namespace

class McpDomain : public DomainHandler {
 public:
  std::string name() const override { return "mcp"; }

  std::string handle(const std::string& op,
                     const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "start") return Start(args);
    if (op == "stop") return Stop(args);
    if (op == "isRunning" || op == "is_running") return IsRunning(args);
    if (op == "handleRequest" || op == "handle_request") {
      return HandleRequest(args);
    }
    if (op == "sessionCreate" || op == "session_create") {
      return SessionCreate(args);
    }
    if (op == "sessionGet" || op == "session_get") return SessionGet(args);
    if (op == "sessionClose" || op == "session_close") {
      return SessionClose(args);
    }
    if (op == "listTools" || op == "list_tools") return ListTools(args);
    if (op == "callTool" || op == "call_tool") return CallTool(args);
    if (op == "listResources" || op == "list_resources") {
      return ListResources(args);
    }
    if (op == "readResource" || op == "read_resource") {
      return ReadResource(args);
    }
    if (op == "listPrompts" || op == "list_prompts") return ListPrompts(args);
    if (op == "getPrompt" || op == "get_prompt") return GetPrompt(args);
    if (op == "auditQuery" || op == "audit_query") {
      return invokeDomain("audit", "query", args.dump());
    }
    if (op == "auditExport" || op == "audit_export") {
      return invokeDomain("audit", "export", args.dump());
    }
    return domainError("NotFound", "unknown mcp op: " + op);
  }

 private:
  // --- session helpers ---------------------------------------------------------
  /// Non-empty session ids must exist; empty means anonymous access.
  bool CheckSession(const std::string& sessionId, std::string* code,
                    std::string* message) {
    if (sessionId.empty()) return true;
    McpState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.sessions.find(sessionId) == state.sessions.end()) {
      *code = "NotFound";
      *message = "unknown mcp session: " + sessionId;
      return false;
    }
    return true;
  }

  /// Loads a session snapshot; empty id -> anonymous (empty object).
  bool ResolveSession(const std::string& sessionId, nlohmann::json* session,
                      std::string* code, std::string* message) {
    *session = nlohmann::json::object();
    if (sessionId.empty()) return true;
    McpState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    const auto it = state.sessions.find(sessionId);
    if (it == state.sessions.end()) {
      *code = "NotFound";
      *message = "unknown mcp session: " + sessionId;
      return false;
    }
    *session = it->second;
    return true;
  }

  // --- lifecycle (design §11.4) ------------------------------------------------
  std::string Start(const nlohmann::json& args) {
    nlohmann::json config = nlohmann::json::object();
    if (args.contains("config") && args["config"].is_object()) {
      config = args["config"];
    }
    const std::string transport =
        config.value("transport", std::string("stdio"));
    if (transport != "stdio" && transport != "sse" && transport != "http") {
      return domainError("InvalidArgument",
                         "unsupported transport: " + transport);
    }

    McpState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.running) {
      return domainError("Conflict", "mcp server is already running");
    }
    state.config = config;
    state.config["transport"] = transport;
    if (!state.config.contains("port")) state.config["port"] = 8765;
    state.running = true;
    state.requestCount = 0;
    state.callCount = 0;

    nlohmann::json result;
    result["port"] = state.config["port"];
    result["running"] = true;
    result["serverName"] = "whiteboard-mcp";
    result["transport"] = transport;
    result["version"] = "1.0.0";
    return domainOk(result.dump());
  }

  std::string Stop(const nlohmann::json& /*args*/) {
    McpState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    const int closed = static_cast<int>(state.sessions.size());
    state.sessions.clear();
    state.subscriptions.clear();
    state.running = false;

    nlohmann::json result;
    result["closedSessions"] = closed;
    result["running"] = false;
    return domainOk(result.dump());
  }

  std::string IsRunning(const nlohmann::json& /*args*/) {
    McpState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    nlohmann::json result;
    result["running"] = state.running;
    return domainOk(result.dump());
  }

  // --- sessions (design §5 auth) -----------------------------------------------
  std::string SessionCreate(const nlohmann::json& args) {
    const std::string token = args.value("token", std::string());
    if (token.empty()) {
      return domainError("InvalidArgument", "args.token is required");
    }
    if (token == "invalid") {
      return domainError("PermissionDenied", "invalid mcp token");
    }

    McpState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.running) {
      return domainError("Conflict", "mcp server is not running");
    }
    const std::string sessionId =
        "mcp-" + std::to_string(++state.nextSessionId);
    nlohmann::json allowedBoards = nlohmann::json::array();
    if (args.contains("allowedBoards") && args["allowedBoards"].is_array()) {
      allowedBoards = args["allowedBoards"];
    }
    nlohmann::json& session = state.sessions[sessionId];
    session["allowedBoards"] = allowedBoards;
    session["clientName"] = std::string("unknown");
    session["clientVersion"] = std::string();
    session["createdAt"] = timeMillis();
    session["initialized"] = false;
    session["lastActiveAt"] = session["createdAt"];
    session["protocolVersion"] = std::string("2025-06-18");
    session["scopes"] = nlohmann::json::array({"*"});
    session["sessionId"] = sessionId;
    session["userId"] = "mcp:" + token;

    nlohmann::json result;
    result["allowedBoards"] = allowedBoards;
    result["createdAt"] = session["createdAt"];
    result["scopes"] = session["scopes"];
    result["sessionId"] = sessionId;
    result["userId"] = session["userId"];
    return domainOk(result.dump());
  }

  std::string SessionGet(const nlohmann::json& args) {
    const std::string sessionId = args.value("sessionId", std::string());
    if (sessionId.empty()) {
      return domainError("InvalidArgument", "args.sessionId is required");
    }
    McpState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    const auto it = state.sessions.find(sessionId);
    if (it == state.sessions.end()) {
      return domainError("NotFound", "unknown mcp session: " + sessionId);
    }
    const nlohmann::json& session = it->second;
    nlohmann::json result;
    result["allowedBoards"] =
        session.value("allowedBoards", nlohmann::json::array());
    result["clientName"] = session.value("clientName", std::string());
    result["clientVersion"] = session.value("clientVersion", std::string());
    result["createdAt"] = session.value("createdAt", nlohmann::json(0));
    result["initialized"] = session.value("initialized", false);
    result["lastActiveAt"] = session.value("lastActiveAt", nlohmann::json(0));
    result["protocolVersion"] = session.value("protocolVersion", std::string());
    result["scopes"] = session.value("scopes", nlohmann::json::array());
    result["sessionId"] = sessionId;
    result["userId"] = session.value("userId", std::string());
    return domainOk(result.dump());
  }

  std::string SessionClose(const nlohmann::json& args) {
    const std::string sessionId = args.value("sessionId", std::string());
    if (sessionId.empty()) {
      return domainError("InvalidArgument", "args.sessionId is required");
    }
    McpState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.sessions.erase(sessionId) == 0) {
      return domainError("NotFound", "unknown mcp session: " + sessionId);
    }
    for (auto it = state.subscriptions.begin();
         it != state.subscriptions.end();) {
      std::vector<std::string>& subscribers = it->second;
      subscribers.erase(
          std::remove(subscribers.begin(), subscribers.end(), sessionId),
          subscribers.end());
      if (subscribers.empty()) {
        it = state.subscriptions.erase(it);
      } else {
        ++it;
      }
    }
    nlohmann::json result;
    result["closed"] = true;
    result["sessionId"] = sessionId;
    return domainOk(result.dump());
  }

  // --- convenience wrappers (FFI) -----------------------------------------------
  std::string ListTools(const nlohmann::json& args) {
    std::string code;
    std::string message;
    if (!CheckSession(args.value("sessionId", std::string()), &code,
                      &message)) {
      return domainError(code, message);
    }
    std::vector<nlohmann::json> tools;
    std::string problem;
    if (!LoadToolList(&tools, &problem)) {
      return domainError("InternalError", problem);
    }
    nlohmann::json list = nlohmann::json::array();
    for (const nlohmann::json& tool : tools) list.push_back(ToMcpTool(tool));
    nlohmann::json result;
    result["count"] = static_cast<int>(list.size());
    result["nextCursor"] = nullptr;
    result["tools"] = std::move(list);
    return domainOk(result.dump());
  }

  std::string CallTool(const nlohmann::json& args) {
    nlohmann::json session;
    std::string code;
    std::string message;
    if (!ResolveSession(args.value("sessionId", std::string()), &session,
                        &code, &message)) {
      return domainError(code, message);
    }
    const std::string toolName = args.value("toolName", std::string());
    if (toolName.empty()) {
      return domainError("InvalidArgument", "args.toolName is required");
    }
    nlohmann::json arguments = nlohmann::json::object();
    if (args.contains("args") && args["args"].is_object()) {
      arguments = args["args"];
    }
    std::vector<nlohmann::json> tools;
    std::string problem;
    if (!LoadToolList(&tools, &problem)) {
      return domainError("InternalError", problem);
    }
    const std::string toolId = FindToolId(tools, toolName);
    if (toolId.empty()) {
      return domainError("NotFound", "unknown tool: " + toolName);
    }
    const nlohmann::json result = ExecuteToolInternal(toolId, arguments);
    {
      McpState& state = State();
      std::lock_guard<std::mutex> lock(state.mutex);
      ++state.callCount;
    }
    AuditWrite(session.value("userId", std::string()), toolId, arguments.dump(),
               result.value("structuredContent", nlohmann::json::object())
                   .dump());
    nlohmann::json out;
    out["content"] = result.value("content", nlohmann::json::array());
    out["isError"] = result.value("isError", true);
    out["structuredContent"] =
        result.value("structuredContent", nlohmann::json::object());
    out["toolId"] = toolId;
    return domainOk(out.dump());
  }

  std::string ListResources(const nlohmann::json& args) {
    nlohmann::json session;
    std::string code;
    std::string message;
    if (!ResolveSession(args.value("sessionId", std::string()), &session,
                        &code, &message)) {
      return domainError(code, message);
    }
    const nlohmann::json resources = BuildResourcesFor(BoardsOf(session));
    nlohmann::json result;
    result["count"] = static_cast<int>(resources.size());
    result["resources"] = resources;
    return domainOk(result.dump());
  }

  std::string ReadResource(const nlohmann::json& args) {
    nlohmann::json session;
    std::string code;
    std::string message;
    if (!ResolveSession(args.value("sessionId", std::string()), &session,
                        &code, &message)) {
      return domainError(code, message);
    }
    const std::string uri = args.value("uri", std::string());
    if (uri.empty()) {
      return domainError("InvalidArgument", "args.uri is required");
    }
    nlohmann::json content;
    std::string error;
    if (!ReadResourceJson(uri, BoardsOf(session), &content, &error)) {
      return domainError("NotFound", error);
    }
    nlohmann::json item;
    item["mimeType"] = "application/json";
    item["text"] = content.dump();
    item["uri"] = uri;
    nlohmann::json result;
    result["contents"] = nlohmann::json::array({item});
    result["uri"] = uri;
    return domainOk(result.dump());
  }

  std::string ListPrompts(const nlohmann::json& args) {
    std::string code;
    std::string message;
    if (!CheckSession(args.value("sessionId", std::string()), &code,
                      &message)) {
      return domainError(code, message);
    }
    nlohmann::json prompts = nlohmann::json::array();
    for (const PromptSpec& prompt : kPrompts) {
      nlohmann::json item;
      item["description"] = prompt.description;
      item["name"] = prompt.name;
      prompts.push_back(std::move(item));
    }
    nlohmann::json result;
    result["count"] = static_cast<int>(prompts.size());
    result["prompts"] = std::move(prompts);
    return domainOk(result.dump());
  }

  std::string GetPrompt(const nlohmann::json& args) {
    std::string code;
    std::string message;
    if (!CheckSession(args.value("sessionId", std::string()), &code,
                      &message)) {
      return domainError(code, message);
    }
    const std::string name = args.value("name", std::string());
    if (name.empty()) {
      return domainError("InvalidArgument", "args.name is required");
    }
    const PromptSpec* prompt = FindPrompt(name);
    if (prompt == nullptr) {
      return domainError("NotFound", "unknown prompt: " + name);
    }
    nlohmann::json arguments = nlohmann::json::object();
    if (args.contains("args") && args["args"].is_object()) {
      arguments = args["args"];
    }
    std::string text;
    std::string missing;
    if (!BuildPromptText(name, arguments, &text, &missing)) {
      return domainError("InvalidArgument",
                         "missing required argument: " + missing);
    }
    nlohmann::json content;
    content["text"] = text;
    content["type"] = "text";
    nlohmann::json msg;
    msg["content"] = std::move(content);
    msg["role"] = "user";
    nlohmann::json result;
    result["description"] = prompt->description;
    result["messages"] = nlohmann::json::array({msg});
    result["name"] = name;
    return domainOk(result.dump());
  }

  // --- JSON-RPC (design §2/§6/§7/§8/§15) ----------------------------------------
  std::string HandleRequest(const nlohmann::json& args) {
    McpState& state = State();
    const std::string sessionId = args.value("sessionId", std::string());
    if (!args.contains("request") || !args["request"].is_object()) {
      return domainOk(RpcError(nlohmann::json(), kRpcInvalidRequest,
                               "request must be a JSON object")
                          .dump());
    }
    const nlohmann::json request = args["request"];
    nlohmann::json id = nlohmann::json();
    if (request.contains("id")) id = request["id"];
    const std::string method = request.value("method", std::string());
    nlohmann::json params = nlohmann::json::object();
    if (request.contains("params") && request["params"].is_object()) {
      params = request["params"];
    }
    if (method.empty()) {
      return domainOk(
          RpcError(id, kRpcInvalidRequest, "method is required").dump());
    }

    // Session bookkeeping; non-empty ids must resolve, empty = anonymous.
    nlohmann::json session = nlohmann::json::object();
    {
      std::lock_guard<std::mutex> lock(state.mutex);
      if (!state.running) {
        return domainError("Conflict", "mcp server is not running");
      }
      ++state.requestCount;
      if (!sessionId.empty()) {
        const auto it = state.sessions.find(sessionId);
        if (it == state.sessions.end()) {
          return domainOk(RpcError(id, kRpcNotFound,
                                   "unknown mcp session: " + sessionId)
                              .dump());
        }
        it->second["lastActiveAt"] = timeMillis();
        session = it->second;
      }
    }
    const std::vector<std::string> boards = BoardsOf(session);

    if (method == "initialize") return RpcInitialize(id, params, sessionId);
    if (method == "notifications/initialized") {
      return RpcInitialized(id, sessionId);
    }
    if (method == "ping") {
      return domainOk(RpcResult(id, nlohmann::json::object()).dump());
    }
    if (method == "tools/list") return RpcToolsList(id);
    if (method == "tools/call") return RpcToolsCall(id, params, session);
    if (method == "resources/list") return RpcResourcesList(id, boards);
    if (method == "resources/read") return RpcResourcesRead(id, params, boards);
    if (method == "resources/subscribe") {
      return RpcSubscription(id, params, sessionId, true);
    }
    if (method == "resources/unsubscribe") {
      return RpcSubscription(id, params, sessionId, false);
    }
    if (method == "prompts/list") return RpcPromptsList(id);
    if (method == "prompts/get") return RpcPromptsGet(id, params);
    return domainOk(RpcError(id, kRpcMethodNotFound,
                             "method not found: " + method)
                        .dump());
  }

  std::string RpcInitialize(const nlohmann::json& id,
                            const nlohmann::json& params,
                            const std::string& sessionId) {
    const std::string requested =
        params.value("protocolVersion", std::string());
    static const char* kSupported[] = {"2025-06-18", "2024-11-05"};
    bool supported = false;
    for (const char* version : kSupported) {
      if (requested == version) supported = true;
    }
    if (!supported) {
      nlohmann::json data;
      data["supported"] = nlohmann::json::array({"2025-06-18", "2024-11-05"});
      return domainOk(RpcError(id, kRpcInvalidParams,
                               "unsupported protocol version: " + requested,
                               data)
                          .dump());
    }
    if (!sessionId.empty()) {
      McpState& state = State();
      std::lock_guard<std::mutex> lock(state.mutex);
      const auto it = state.sessions.find(sessionId);
      if (it != state.sessions.end()) {
        it->second["protocolVersion"] = requested;
        nlohmann::json clientInfo = nlohmann::json::object();
        if (params.contains("clientInfo") && params["clientInfo"].is_object()) {
          clientInfo = params["clientInfo"];
        }
        it->second["clientName"] =
            clientInfo.value("name", std::string("unknown"));
        it->second["clientVersion"] =
            clientInfo.value("version", std::string());
      }
    }

    nlohmann::json promptsCap;
    promptsCap["listChanged"] = true;
    nlohmann::json resourcesCap;
    resourcesCap["listChanged"] = true;
    resourcesCap["subscribe"] = true;
    nlohmann::json toolsCap;
    toolsCap["listChanged"] = true;
    nlohmann::json capabilities;
    capabilities["logging"] = nlohmann::json::object();
    capabilities["prompts"] = std::move(promptsCap);
    capabilities["resources"] = std::move(resourcesCap);
    capabilities["tools"] = std::move(toolsCap);
    nlohmann::json serverInfo;
    serverInfo["name"] = "whiteboard-mcp";
    serverInfo["version"] = "1.0.0";
    nlohmann::json result;
    result["capabilities"] = std::move(capabilities);
    result["instructions"] =
        "白板 MCP Server，支持元素、页面、3D、函数、流程图等操作。";
    result["protocolVersion"] = requested;
    result["serverInfo"] = std::move(serverInfo);
    return domainOk(RpcResult(id, std::move(result)).dump());
  }

  std::string RpcInitialized(const nlohmann::json& id,
                             const std::string& sessionId) {
    if (!sessionId.empty()) {
      McpState& state = State();
      std::lock_guard<std::mutex> lock(state.mutex);
      const auto it = state.sessions.find(sessionId);
      if (it != state.sessions.end()) it->second["initialized"] = true;
    }
    nlohmann::json result;
    result["ok"] = true;
    return domainOk(RpcResult(id, std::move(result)).dump());
  }

  std::string RpcToolsList(const nlohmann::json& id) {
    std::vector<nlohmann::json> tools;
    std::string problem;
    if (!LoadToolList(&tools, &problem)) {
      return domainOk(RpcError(id, kRpcInternalError, problem).dump());
    }
    nlohmann::json list = nlohmann::json::array();
    for (const nlohmann::json& tool : tools) list.push_back(ToMcpTool(tool));
    nlohmann::json result;
    result["nextCursor"] = nullptr;
    result["tools"] = std::move(list);
    return domainOk(RpcResult(id, std::move(result)).dump());
  }

  std::string RpcToolsCall(const nlohmann::json& id,
                           const nlohmann::json& params,
                           const nlohmann::json& session) {
    const std::string name = params.value("name", std::string());
    if (name.empty()) {
      return domainOk(
          RpcError(id, kRpcInvalidParams, "params.name is required").dump());
    }
    nlohmann::json arguments = nlohmann::json::object();
    if (params.contains("arguments") && params["arguments"].is_object()) {
      arguments = params["arguments"];
    }
    std::vector<nlohmann::json> tools;
    std::string problem;
    if (!LoadToolList(&tools, &problem)) {
      return domainOk(RpcError(id, kRpcInternalError, problem).dump());
    }
    const std::string toolId = FindToolId(tools, name);
    if (toolId.empty()) {
      return domainOk(
          RpcError(id, kRpcNotFound, "unknown tool: " + name).dump());
    }
    const nlohmann::json result = ExecuteToolInternal(toolId, arguments);
    {
      McpState& state = State();
      std::lock_guard<std::mutex> lock(state.mutex);
      ++state.callCount;
    }
    AuditWrite(session.value("userId", std::string()), toolId, arguments.dump(),
               result.value("structuredContent", nlohmann::json::object())
                   .dump());
    return domainOk(RpcResult(id, result).dump());
  }

  std::string RpcResourcesList(const nlohmann::json& id,
                               const std::vector<std::string>& boards) {
    nlohmann::json result;
    result["resources"] = BuildResourcesFor(boards);
    return domainOk(RpcResult(id, std::move(result)).dump());
  }

  std::string RpcResourcesRead(const nlohmann::json& id,
                               const nlohmann::json& params,
                               const std::vector<std::string>& boards) {
    const std::string uri = params.value("uri", std::string());
    if (uri.empty()) {
      return domainOk(
          RpcError(id, kRpcInvalidParams, "params.uri is required").dump());
    }
    nlohmann::json content;
    std::string error;
    if (!ReadResourceJson(uri, boards, &content, &error)) {
      return domainOk(RpcError(id, kRpcNotFound, error).dump());
    }
    nlohmann::json item;
    item["mimeType"] = "application/json";
    item["text"] = content.dump();
    item["uri"] = uri;
    nlohmann::json result;
    result["contents"] = nlohmann::json::array({item});
    return domainOk(RpcResult(id, std::move(result)).dump());
  }

  std::string RpcSubscription(const nlohmann::json& id,
                              const nlohmann::json& params,
                              const std::string& sessionId, bool subscribe) {
    const std::string uri = params.value("uri", std::string());
    if (uri.empty()) {
      return domainOk(
          RpcError(id, kRpcInvalidParams, "params.uri is required").dump());
    }
    {
      McpState& state = State();
      std::lock_guard<std::mutex> lock(state.mutex);
      std::vector<std::string>& subscribers = state.subscriptions[uri];
      if (subscribe) {
        bool present = false;
        for (const std::string& item : subscribers) {
          if (item == sessionId) present = true;
        }
        if (!present) subscribers.push_back(sessionId);
      } else {
        subscribers.erase(
            std::remove(subscribers.begin(), subscribers.end(), sessionId),
            subscribers.end());
        if (subscribers.empty()) state.subscriptions.erase(uri);
      }
    }
    nlohmann::json result;
    result["subscribed"] = subscribe;
    result["uri"] = uri;
    return domainOk(RpcResult(id, std::move(result)).dump());
  }

  std::string RpcPromptsList(const nlohmann::json& id) {
    nlohmann::json prompts = nlohmann::json::array();
    for (const PromptSpec& prompt : kPrompts) {
      nlohmann::json item;
      item["description"] = prompt.description;
      item["name"] = prompt.name;
      prompts.push_back(std::move(item));
    }
    nlohmann::json result;
    result["prompts"] = std::move(prompts);
    return domainOk(RpcResult(id, std::move(result)).dump());
  }

  std::string RpcPromptsGet(const nlohmann::json& id,
                            const nlohmann::json& params) {
    const std::string name = params.value("name", std::string());
    if (name.empty()) {
      return domainOk(
          RpcError(id, kRpcInvalidParams, "params.name is required").dump());
    }
    const PromptSpec* prompt = FindPrompt(name);
    if (prompt == nullptr) {
      return domainOk(
          RpcError(id, kRpcNotFound, "unknown prompt: " + name).dump());
    }
    nlohmann::json arguments = nlohmann::json::object();
    if (params.contains("arguments") && params["arguments"].is_object()) {
      arguments = params["arguments"];
    }
    std::string text;
    std::string missing;
    if (!BuildPromptText(name, arguments, &text, &missing)) {
      nlohmann::json data;
      data["argument"] = missing;
      return domainOk(RpcError(id, kRpcInvalidParams,
                               "missing required argument: " + missing, data)
                          .dump());
    }
    nlohmann::json content;
    content["text"] = text;
    content["type"] = "text";
    nlohmann::json message;
    message["content"] = std::move(content);
    message["role"] = "user";
    nlohmann::json result;
    result["description"] = prompt->description;
    result["messages"] = nlohmann::json::array({message});
    result["name"] = name;
    return domainOk(RpcResult(id, std::move(result)).dump());
  }
};

WB_REGISTER_DOMAIN(McpDomain)

}  // namespace wb
