// ai/ai.cpp — domain "ai" (task package 1.8).
// Owns: core/src/ai.
//
// Ops (《AI 助手与 MCP 设计》§5.3/§7.2 + FFI forwarding): sessionCreate,
// sessionClose, sessionGet, sendMessage, sendAudio, listMessages,
// executeToolCall, previewToolCall, cancelToolCall, setContext.
//
// Sessions live in a process-wide registry (same pattern as the crdt/sync
// domains). Message generation itself is done by the AI Gateway in a later
// wave; this domain implements the deterministic bookkeeping around it:
// user messages are appended locally, assistant replies arrive through the
// gateway. Tool calls are executed through the shared ToolRegistry
// (domain "tool") so AI operations carry the same audit trail as user
// operations (design principle #1: AI 与用户一致).
//
// Locking: the AI mutex is only held for state reads/writes; tool
// execution (invokeDomain) and audit logging happen OUTSIDE the lock.

#include <mutex>
#include <string>
#include <unordered_map>

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

struct AiState {
  std::mutex mutex;
  std::unordered_map<std::string, nlohmann::json> sessions;
  int nextSessionId = 0;
  int nextMessageId = 0;
  int nextCallId = 0;
};

AiState& State() {
  static AiState state;
  return state;
}

/// Finds a session; fills error code/message when missing.
nlohmann::json* FindSession(AiState& state, const std::string& sessionId,
                            std::string* code, std::string* message) {
  auto it = state.sessions.find(sessionId);
  if (it == state.sessions.end()) {
    *code = "NotFound";
    *message = "unknown ai session: " + sessionId;
    return nullptr;
  }
  return &it->second;
}

/// Finds a tool call inside a session (raw, no error filling).
nlohmann::json* FindCall(nlohmann::json& session, const std::string& callId) {
  if (!session.contains("messages") || !session["messages"].is_array()) {
    return nullptr;
  }
  for (nlohmann::json& message : session["messages"]) {
    if (!message.contains("toolCalls") || !message["toolCalls"].is_array()) {
      continue;
    }
    for (nlohmann::json& call : message["toolCalls"]) {
      if (call.value("id", std::string()) == callId) return &call;
    }
  }
  return nullptr;
}

/// Normalizes a toolCalls[] entry into a stored ToolCall record.
nlohmann::json MakeToolCall(AiState& state, const nlohmann::json& spec) {
  const std::string toolId = spec.value("toolId", std::string());
  std::string argsJson = "{}";
  if (spec.contains("argsJson")) {
    if (spec["argsJson"].is_string()) {
      argsJson = spec["argsJson"].get<std::string>();
    } else {
      argsJson = spec["argsJson"].dump();
    }
  }
  if (argsJson.empty()) argsJson = "{}";
  nlohmann::json call;
  call["argsJson"] = argsJson;
  call["id"] = "call-" + std::to_string(++state.nextCallId);
  call["resultJson"] = "";
  call["status"] = "pending";
  call["timestamp"] = timeMillis();
  call["toolId"] = toolId;
  return call;
}

}  // namespace

class AiDomain : public DomainHandler {
 public:
  std::string name() const override { return "ai"; }

  std::string handle(const std::string& op,
                     const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "sessionCreate" || op == "session_create") {
      return SessionCreate(args);
    }
    if (op == "sessionClose" || op == "session_close") {
      return SessionClose(args);
    }
    if (op == "sessionGet" || op == "session_get") return SessionGet(args);
    if (op == "sendMessage" || op == "send_message") return SendMessage(args);
    if (op == "sendAudio" || op == "send_audio") return SendAudio(args);
    if (op == "listMessages" || op == "list_messages") {
      return ListMessages(args);
    }
    if (op == "executeToolCall" || op == "execute_tool_call") {
      return ExecuteToolCall(args);
    }
    if (op == "previewToolCall" || op == "preview_tool_call") {
      return PreviewToolCall(args);
    }
    if (op == "cancelToolCall" || op == "cancel_tool_call") {
      return CancelToolCall(args);
    }
    if (op == "setContext" || op == "set_context") return SetContext(args);
    return domainError("NotFound", "unknown ai op: " + op);
  }

 private:
  // --- sessions ---------------------------------------------------------------
  std::string SessionCreate(const nlohmann::json& args) {
    const std::string boardId = args.value("boardId", std::string());
    if (boardId.empty()) {
      return domainError("InvalidArgument", "args.boardId is required");
    }
    const std::string userId = args.value("userId", std::string());
    if (userId.empty()) {
      return domainError("InvalidArgument", "args.userId is required");
    }

    AiState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    const std::string sessionId = "ai-" + std::to_string(++state.nextSessionId);
    nlohmann::json& session = state.sessions[sessionId];
    session["boardId"] = boardId;
    session["userId"] = userId;
    session["pageId"] = args.value("pageId", std::string());
    session["selection"] = args.value("selection", nlohmann::json::array());
    session["context"] = nlohmann::json::object();
    session["createdAt"] = timeMillis();
    session["updatedAt"] = session["createdAt"];
    session["messages"] = nlohmann::json::array();

    nlohmann::json result;
    result["boardId"] = boardId;
    result["createdAt"] = session["createdAt"];
    result["sessionId"] = sessionId;
    result["userId"] = userId;
    return domainOk(result.dump());
  }

  std::string SessionClose(const nlohmann::json& args) {
    const std::string sessionId = args.value("sessionId", std::string());
    if (sessionId.empty()) {
      return domainError("InvalidArgument", "args.sessionId is required");
    }
    AiState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.sessions.erase(sessionId) == 0) {
      return domainError("NotFound", "unknown ai session: " + sessionId);
    }
    nlohmann::json result;
    result["closed"] = true;
    result["sessionId"] = sessionId;
    return domainOk(result.dump());
  }

  std::string SessionGet(const nlohmann::json& args) {
    const std::string sessionId = args.value("sessionId", std::string());
    if (sessionId.empty()) {
      return domainError("InvalidArgument", "args.sessionId is required");
    }
    AiState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    std::string code;
    std::string message;
    nlohmann::json* session = FindSession(state, sessionId, &code, &message);
    if (session == nullptr) return domainError(code, message);

    nlohmann::json result;
    result["boardId"] = session->value("boardId", std::string());
    result["context"] = session->value("context", nlohmann::json::object());
    result["createdAt"] = session->value("createdAt", std::int64_t(0));
    result["messageCount"] = static_cast<int>(
        session->value("messages", nlohmann::json::array()).size());
    result["pageId"] = session->value("pageId", std::string());
    result["selection"] = session->value("selection", nlohmann::json::array());
    result["sessionId"] = sessionId;
    result["updatedAt"] = session->value("updatedAt", std::int64_t(0));
    result["userId"] = session->value("userId", std::string());
    return domainOk(result.dump());
  }

  // --- messages ----------------------------------------------------------------
  std::string SendMessage(const nlohmann::json& args) {
    const std::string sessionId = args.value("sessionId", std::string());
    if (sessionId.empty()) {
      return domainError("InvalidArgument", "args.sessionId is required");
    }
    if (!args.contains("message") || !args["message"].is_string()) {
      return domainError("InvalidArgument", "args.message is required");
    }
    const std::string message = args["message"].get<std::string>();
    if (message.empty()) {
      return domainError("InvalidArgument", "args.message must not be empty");
    }

    AiState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    std::string code;
    std::string problem;
    nlohmann::json* session = FindSession(state, sessionId, &code, &problem);
    if (session == nullptr) return domainError(code, problem);

    nlohmann::json calls = nlohmann::json::array();
    if (args.contains("toolCalls")) {
      if (!args["toolCalls"].is_array()) {
        return domainError("InvalidArgument", "args.toolCalls must be an array");
      }
      for (const nlohmann::json& spec : args["toolCalls"]) {
        if (!spec.is_object() || !spec.contains("toolId") ||
            !spec["toolId"].is_string() ||
            spec["toolId"].get<std::string>().empty()) {
          return domainError("InvalidArgument",
                             "toolCalls[].toolId is required");
        }
        calls.push_back(MakeToolCall(state, spec));
      }
    }

    nlohmann::json record;
    record["audioUrl"] = "";
    record["content"] = message;
    record["id"] = "msg-" + std::to_string(++state.nextMessageId);
    record["role"] = "user";
    record["timestamp"] = timeMillis();
    record["toolCalls"] = std::move(calls);
    (*session)["messages"].push_back(record);
    (*session)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["messageCount"] = static_cast<int>((*session)["messages"].size());
    result["messageId"] = record["id"];
    result["sessionId"] = sessionId;
    result["stub"] = true;  // AI Gateway 接入前，助手回复由网关推送
    return domainOk(result.dump());
  }

  std::string SendAudio(const nlohmann::json& args) {
    const std::string sessionId = args.value("sessionId", std::string());
    if (sessionId.empty()) {
      return domainError("InvalidArgument", "args.sessionId is required");
    }
    const std::string audioData = args.value("audioData", std::string());
    if (audioData.empty()) {
      return domainError("InvalidArgument", "args.audioData is required");
    }

    AiState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    std::string code;
    std::string problem;
    nlohmann::json* session = FindSession(state, sessionId, &code, &problem);
    if (session == nullptr) return domainError(code, problem);

    nlohmann::json record;
    record["audioUrl"] = audioData;
    record["content"] = "";
    record["id"] = "msg-" + std::to_string(++state.nextMessageId);
    record["role"] = "user";
    record["timestamp"] = timeMillis();
    record["toolCalls"] = nlohmann::json::array();
    (*session)["messages"].push_back(record);
    (*session)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["messageId"] = record["id"];
    result["sessionId"] = sessionId;
    result["stub"] = true;  // 流式 ASR 由 AI Gateway 接入
    result["transcription"] = "";
    return domainOk(result.dump());
  }

  std::string ListMessages(const nlohmann::json& args) {
    const std::string sessionId = args.value("sessionId", std::string());
    if (sessionId.empty()) {
      return domainError("InvalidArgument", "args.sessionId is required");
    }
    AiState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    std::string code;
    std::string message;
    nlohmann::json* session = FindSession(state, sessionId, &code, &message);
    if (session == nullptr) return domainError(code, message);

    const nlohmann::json messages =
        session->value("messages", nlohmann::json::array());
    nlohmann::json result;
    result["count"] = static_cast<int>(messages.size());
    result["messages"] = messages;
    result["sessionId"] = sessionId;
    return domainOk(result.dump());
  }

  // --- tool calls ---------------------------------------------------------------
  /// Shared lookup: returns the call record and its owning session id.
  static nlohmann::json* LookupCall(AiState& state,
                                    const std::string& sessionId,
                                    const std::string& toolCallId,
                                    std::string* code, std::string* message) {
    nlohmann::json* session = FindSession(state, sessionId, code, message);
    if (session == nullptr) return nullptr;
    nlohmann::json* call = FindCall(*session, toolCallId);
    if (call == nullptr) {
      *code = "NotFound";
      *message = "unknown tool call: " + toolCallId;
    }
    return call;
  }

  std::string ExecuteToolCall(const nlohmann::json& args) {
    const std::string sessionId = args.value("sessionId", std::string());
    const std::string toolCallId = args.value("toolCallId", std::string());
    if (sessionId.empty()) {
      return domainError("InvalidArgument", "args.sessionId is required");
    }
    if (toolCallId.empty()) {
      return domainError("InvalidArgument", "args.toolCallId is required");
    }

    std::string toolId;
    std::string callArgs;
    std::string userId;
    {
      AiState& state = State();
      std::lock_guard<std::mutex> lock(state.mutex);
      std::string code;
      std::string message;
      nlohmann::json* call =
          LookupCall(state, sessionId, toolCallId, &code, &message);
      if (call == nullptr) return domainError(code, message);
      const std::string status = call->value("status", std::string("pending"));
      if (status != "pending") {
        return domainError("Conflict",
                           "tool call is not pending: " + status);
      }
      (*call)["status"] = "running";
      toolId = call->value("toolId", std::string());
      callArgs = call->value("argsJson", std::string("{}"));
      nlohmann::json* session = FindSession(state, sessionId, &code, &message);
      if (session != nullptr) {
        userId = session->value("userId", std::string());
        (*session)["updatedAt"] = timeMillis();
      }
    }

    // Execute outside the AI lock: the tool layer touches other domains.
    nlohmann::json toolArgs = nlohmann::json::parse(callArgs, nullptr, false);
    if (!toolArgs.is_object()) toolArgs = nlohmann::json::object();
    nlohmann::json toolArgsWrap;
    toolArgsWrap["args"] = toolArgs;
    toolArgsWrap["toolId"] = toolId;
    const std::string response =
        invokeDomain("tool", "execute", toolArgsWrap.dump());
    const nlohmann::json parsed =
        nlohmann::json::parse(response, nullptr, false);
    const bool succeeded =
        parsed.is_object() && parsed.value("ok", false) == true;

    {
      AiState& state = State();
      std::lock_guard<std::mutex> lock(state.mutex);
      std::string code;
      std::string message;
      nlohmann::json* session = FindSession(state, sessionId, &code, &message);
      nlohmann::json* call =
          session != nullptr ? FindCall(*session, toolCallId) : nullptr;
      if (call != nullptr) {
        (*call)["status"] = succeeded ? "success" : "error";
        (*call)["resultJson"] =
            succeeded ? parsed["result"].dump() : response;
      }
      if (session != nullptr) (*session)["updatedAt"] = timeMillis();
    }

    // Audit every AI tool call, mirroring user-driven tool execution.
    nlohmann::json audit;
    audit["argsJson"] = callArgs;
    audit["fromAI"] = true;
    audit["resultJson"] = succeeded ? parsed["result"].dump() : response;
    audit["toolId"] = toolId;
    audit["userId"] = userId.empty() ? "ai:anonymous" : userId;
    invokeDomain("audit", "log", nlohmann::json{{"entry", audit}}.dump());

    nlohmann::json result;
    result["sessionId"] = sessionId;
    result["succeeded"] = succeeded;
    result["toolCallId"] = toolCallId;
    result["toolId"] = toolId;
    result["response"] = parsed;
    return domainOk(result.dump());
  }

  std::string PreviewToolCall(const nlohmann::json& args) {
    const std::string sessionId = args.value("sessionId", std::string());
    const std::string toolCallId = args.value("toolCallId", std::string());
    if (sessionId.empty()) {
      return domainError("InvalidArgument", "args.sessionId is required");
    }
    if (toolCallId.empty()) {
      return domainError("InvalidArgument", "args.toolCallId is required");
    }
    AiState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    std::string code;
    std::string message;
    nlohmann::json* call =
        LookupCall(state, sessionId, toolCallId, &code, &message);
    if (call == nullptr) return domainError(code, message);

    nlohmann::json result;
    result["argsJson"] = call->value("argsJson", std::string("{}"));
    result["preview"] = true;  // 幽灵预览由 UI 层渲染半透明效果
    result["sessionId"] = sessionId;
    result["status"] = call->value("status", std::string("pending"));
    result["toolCallId"] = toolCallId;
    result["toolId"] = call->value("toolId", std::string());
    return domainOk(result.dump());
  }

  std::string CancelToolCall(const nlohmann::json& args) {
    const std::string sessionId = args.value("sessionId", std::string());
    const std::string toolCallId = args.value("toolCallId", std::string());
    if (sessionId.empty()) {
      return domainError("InvalidArgument", "args.sessionId is required");
    }
    if (toolCallId.empty()) {
      return domainError("InvalidArgument", "args.toolCallId is required");
    }
    AiState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    std::string code;
    std::string message;
    nlohmann::json* call =
        LookupCall(state, sessionId, toolCallId, &code, &message);
    if (call == nullptr) return domainError(code, message);
    const std::string status = call->value("status", std::string("pending"));
    if (status != "pending") {
      return domainError("Conflict", "tool call cannot be cancelled: " + status);
    }
    (*call)["status"] = "cancelled";
    nlohmann::json result;
    result["cancelled"] = true;
    result["sessionId"] = sessionId;
    result["status"] = "cancelled";
    result["toolCallId"] = toolCallId;
    return domainOk(result.dump());
  }

  // --- context -----------------------------------------------------------------
  std::string SetContext(const nlohmann::json& args) {
    const std::string sessionId = args.value("sessionId", std::string());
    if (sessionId.empty()) {
      return domainError("InvalidArgument", "args.sessionId is required");
    }
    if (!args.contains("context") || !args["context"].is_object()) {
      return domainError("InvalidArgument", "args.context must be an object");
    }
    AiState& state = State();
    std::lock_guard<std::mutex> lock(state.mutex);
    std::string code;
    std::string message;
    nlohmann::json* session = FindSession(state, sessionId, &code, &message);
    if (session == nullptr) return domainError(code, message);

    nlohmann::json& context = (*session)["context"];
    for (auto it = args["context"].begin(); it != args["context"].end(); ++it) {
      context[it.key()] = it.value();
    }
    (*session)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["context"] = context;
    result["sessionId"] = sessionId;
    result["updatedAt"] = (*session)["updatedAt"];
    return domainOk(result.dump());
  }
};

WB_REGISTER_DOMAIN(AiDomain)

}  // namespace wb
