// crdt/crdt.cpp — domain "crdt" (task package 1.7).
// Owns: core/src/crdt.
//
// Ops (《C++ 核心引擎接口设计》§12.1): create, applyLocal, applyRemote,
// encodeState, decodeState, encodeUpdate, merge, list.
//
// Op-based CRDT document: every mutation is an immutable operation
// {actor, seq, key, value, timestamp, origin}. The materialized state is
// a last-writer-wins register map keyed by `key`; ties on timestamp are
// broken deterministically by actor id. Documents live in a process-wide
// registry keyed by docId, mirroring how SceneStore holds boards.
//
// Merge is set-union over operations identified by (actor, seq) followed
// by an LWW replay, so merging is commutative, associative and idempotent.
// Merging copies therefore requires each copy to use a distinct actor id
// (pass "actor" to create); otherwise (actor, seq) cannot tell ops apart.

#include <algorithm>
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

struct CrdtDocument {
  std::string docId;
  std::string actor = "local";
  int seq = 0;                            // local op counter
  nlohmann::json ops = nlohmann::json::array();    // op log
  nlohmann::json state = nlohmann::json::object(); // key -> register
};

/// Process-wide document registry; guarded by the domain's mutex.
struct Registry {
  std::mutex mutex;
  std::unordered_map<std::string, CrdtDocument> docs;
  int nextId = 0;
};

Registry& Docs() {
  static Registry registry;
  return registry;
}

bool HasOp(const CrdtDocument& doc, const std::string& actor, int seq) {
  for (const nlohmann::json& op : doc.ops) {
    if (op.value("actor", std::string()) == actor &&
        op.value("seq", 0) == seq) {
      return true;
    }
  }
  return false;
}

int MaxSeq(const CrdtDocument& doc, const std::string& actor) {
  int maxSeq = 0;
  for (const nlohmann::json& op : doc.ops) {
    if (op.value("actor", std::string()) == actor) {
      maxSeq = std::max(maxSeq, op.value("seq", 0));
    }
  }
  return maxSeq;
}

/// LWW decision: apply when the incoming timestamp is newer; ties are
/// broken by the lexicographically larger actor id.
bool ShouldApply(const nlohmann::json& state, const std::string& key,
                 std::int64_t timestamp, const std::string& actor) {
  if (!state.contains(key)) return true;
  const nlohmann::json& current = state[key];
  const std::int64_t currentTs = current.value("timestamp", std::int64_t(0));
  if (timestamp != currentTs) return timestamp > currentTs;
  return actor > current.value("actor", std::string());
}

/// Applies one op to the register map; returns whether the register moved.
bool ApplyRegister(const nlohmann::json& op, nlohmann::json* state) {
  const std::string key = op.value("key", std::string());
  const std::int64_t timestamp = op.value("timestamp", std::int64_t(0));
  const std::string actor = op.value("actor", std::string());
  if (!ShouldApply(*state, key, timestamp, actor)) return false;
  nlohmann::json& slot = (*state)[key];
  slot["value"] = op.value("value", nlohmann::json());
  slot["timestamp"] = timestamp;
  slot["actor"] = actor;
  return true;
}

std::string MakeOp(const nlohmann::json& operation, const std::string& actor,
                   int seq, const char* origin, nlohmann::json* op) {
  if (!operation.is_object() || operation.empty()) {
    return "args.operation is required";
  }
  const std::string key = operation.value("key", std::string());
  if (key.empty()) return "operation.key is required";
  if (!operation.contains("value")) return "operation.value is required";
  (*op)["key"] = key;
  (*op)["value"] = operation["value"];
  (*op)["actor"] = actor;
  (*op)["seq"] = seq;
  (*op)["origin"] = origin;
  (*op)["timestamp"] = operation.contains("timestamp")
                           ? operation["timestamp"].get<std::int64_t>()
                           : timeMillis();
  return std::string();
}

}  // namespace

class CrdtDomain : public DomainHandler {
 public:
  std::string name() const override { return "crdt"; }

  std::string handle(const std::string& op,
                     const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "create") return Create(args);
    if (op == "applyLocal" || op == "apply_local") return ApplyLocal(args);
    if (op == "applyRemote" || op == "apply_remote") {
      return ApplyRemote(args);
    }
    if (op == "encodeState" || op == "encode_state") return EncodeState(args);
    if (op == "decodeState" || op == "decode_state") return DecodeState(args);
    if (op == "encodeUpdate" || op == "encode_update") {
      return EncodeUpdate(args);
    }
    if (op == "merge") return Merge(args);
    if (op == "list") return List(args);
    return domainError("NotFound", "unknown crdt op: " + op);
  }

 private:
  static CrdtDocument* Find(const std::string& docId, std::string* code,
                            std::string* message) {
    auto it = Docs().docs.find(docId);
    if (it == Docs().docs.end()) {
      *code = "NotFound";
      *message = "unknown crdt document: " + docId;
      return nullptr;
    }
    return &it->second;
  }

  // --- ops ------------------------------------------------------------------
  std::string Create(const nlohmann::json& args) {
    std::lock_guard<std::mutex> lock(Docs().mutex);
    std::string docId = args.value("docId", std::string());
    if (docId.empty()) {
      docId = "crdt-" + std::to_string(++Docs().nextId);
    } else if (Docs().docs.count(docId) != 0) {
      return domainError("Conflict", "crdt document exists: " + docId);
    }
    CrdtDocument& doc = Docs().docs[docId];
    doc.docId = docId;
    doc.actor = args.value("actor", std::string("local"));
    nlohmann::json result;
    result["docId"] = docId;
    result["actor"] = doc.actor;
    result["version"] = 0;
    return domainOk(result.dump());
  }

  std::string ApplyLocal(const nlohmann::json& args) {
    const std::string docId = args.value("docId", std::string());
    std::lock_guard<std::mutex> lock(Docs().mutex);
    std::string code;
    std::string message;
    CrdtDocument* doc = Find(docId, &code, &message);
    if (doc == nullptr) return domainError(code, message);
    const std::string actor =
        args.value("actor", doc->actor.empty() ? docId : doc->actor);
    nlohmann::json op;
    const std::string problem = MakeOp(
        args.value("operation", nlohmann::json::object()), actor, doc->seq + 1,
        "local", &op);
    if (!problem.empty()) return domainError("InvalidArgument", problem);
    doc->seq += 1;
    doc->ops.push_back(op);
    const bool applied = ApplyRegister(op, &doc->state);
    nlohmann::json result;
    result["applied"] = applied;
    result["docId"] = docId;
    result["key"] = op["key"];
    result["origin"] = "local";
    result["seq"] = op["seq"];
    result["version"] = static_cast<int>(doc->ops.size());
    return domainOk(result.dump());
  }

  std::string ApplyRemote(const nlohmann::json& args) {
    const std::string docId = args.value("docId", std::string());
    std::lock_guard<std::mutex> lock(Docs().mutex);
    std::string code;
    std::string message;
    CrdtDocument* doc = Find(docId, &code, &message);
    if (doc == nullptr) return domainError(code, message);
    const nlohmann::json operation =
        args.value("operation", nlohmann::json::object());
    if (!operation.is_object() || operation.empty()) {
      return domainError("InvalidArgument", "args.operation is required");
    }
    const std::string actor =
        operation.value("actor", args.value("actor", std::string("remote")));
    int seq = operation.value("seq", 0);
    if (seq <= 0) seq = MaxSeq(*doc, actor) + 1;
    if (HasOp(*doc, actor, seq)) {
      nlohmann::json result;
      result["applied"] = false;
      result["docId"] = docId;
      result["duplicate"] = true;
      result["seq"] = seq;
      result["version"] = static_cast<int>(doc->ops.size());
      return domainOk(result.dump());
    }
    nlohmann::json op;
    const std::string problem = MakeOp(operation, actor, seq, "remote", &op);
    if (!problem.empty()) return domainError("InvalidArgument", problem);
    doc->ops.push_back(op);
    const bool applied = ApplyRegister(op, &doc->state);
    nlohmann::json result;
    result["applied"] = applied;
    result["docId"] = docId;
    result["key"] = op["key"];
    result["origin"] = "remote";
    result["seq"] = seq;
    result["version"] = static_cast<int>(doc->ops.size());
    return domainOk(result.dump());
  }

  std::string EncodeState(const nlohmann::json& args) {
    const std::string docId = args.value("docId", std::string());
    std::lock_guard<std::mutex> lock(Docs().mutex);
    std::string code;
    std::string message;
    CrdtDocument* doc = Find(docId, &code, &message);
    if (doc == nullptr) return domainError(code, message);
    nlohmann::json result;
    result["docId"] = docId;
    result["keyCount"] = static_cast<int>(doc->state.size());
    result["state"] = doc->state.dump();
    result["version"] = static_cast<int>(doc->ops.size());
    return domainOk(result.dump());
  }

  std::string DecodeState(const nlohmann::json& args) {
    const std::string docId = args.value("docId", std::string());
    std::lock_guard<std::mutex> lock(Docs().mutex);
    std::string code;
    std::string message;
    CrdtDocument* doc = Find(docId, &code, &message);
    if (doc == nullptr) return domainError(code, message);
    if (!args.contains("state")) {
      return domainError("InvalidArgument", "args.state is required");
    }
    nlohmann::json state = args["state"];
    if (state.is_string()) {
      state = nlohmann::json::parse(state.get<std::string>(), nullptr, false);
    }
    if (!state.is_object()) {
      return domainError("InvalidArgument", "state must be a JSON object");
    }
    doc->state = std::move(state);
    nlohmann::json result;
    result["decoded"] = true;
    result["docId"] = docId;
    result["keyCount"] = static_cast<int>(doc->state.size());
    result["version"] = static_cast<int>(doc->ops.size());
    return domainOk(result.dump());
  }

  std::string EncodeUpdate(const nlohmann::json& args) {
    const std::string docId = args.value("docId", std::string());
    const int since = args.value("since", 0);
    if (since < 0) {
      return domainError("InvalidArgument", "args.since must be >= 0");
    }
    std::lock_guard<std::mutex> lock(Docs().mutex);
    std::string code;
    std::string message;
    CrdtDocument* doc = Find(docId, &code, &message);
    if (doc == nullptr) return domainError(code, message);
    nlohmann::json update = nlohmann::json::array();
    for (const nlohmann::json& op : doc->ops) {
      if (op.value("seq", 0) > since) update.push_back(op);
    }
    nlohmann::json result;
    result["count"] = static_cast<int>(update.size());
    result["docId"] = docId;
    result["since"] = since;
    result["update"] = std::move(update);
    result["version"] = static_cast<int>(doc->ops.size());
    return domainOk(result.dump());
  }

  std::string Merge(const nlohmann::json& args) {
    const std::string docId = args.value("docId", std::string());
    const std::string otherId = args.value("other", std::string());
    std::lock_guard<std::mutex> lock(Docs().mutex);
    std::string code;
    std::string message;
    CrdtDocument* doc = Find(docId, &code, &message);
    if (doc == nullptr) return domainError(code, message);
    CrdtDocument* other = Find(otherId, &code, &message);
    if (other == nullptr) return domainError(code, message);

    int merged = 0;
    if (other != doc) {
      for (const nlohmann::json& op : other->ops) {
        const std::string actor = op.value("actor", std::string());
        const int seq = op.value("seq", 0);
        if (HasOp(*doc, actor, seq)) continue;
        doc->ops.push_back(op);
        ApplyRegister(op, &doc->state);
        merged += 1;
      }
    }
    nlohmann::json result;
    result["docId"] = docId;
    result["keyCount"] = static_cast<int>(doc->state.size());
    result["merged"] = merged;
    result["other"] = otherId;
    result["version"] = static_cast<int>(doc->ops.size());
    return domainOk(result.dump());
  }

  std::string List(const nlohmann::json& args) {
    (void)args;
    std::lock_guard<std::mutex> lock(Docs().mutex);
    nlohmann::json docs = nlohmann::json::array();
    std::vector<std::string> ids;
    ids.reserve(Docs().docs.size());
    for (const auto& [id, doc] : Docs().docs) ids.push_back(id);
    std::sort(ids.begin(), ids.end());
    for (const std::string& id : ids) {
      const CrdtDocument& doc = Docs().docs.at(id);
      nlohmann::json item;
      item["docId"] = id;
      item["keyCount"] = static_cast<int>(doc.state.size());
      item["version"] = static_cast<int>(doc.ops.size());
      docs.push_back(std::move(item));
    }
    nlohmann::json result;
    result["docs"] = std::move(docs);
    result["count"] = static_cast<int>(result["docs"].size());
    return domainOk(result.dump());
  }
};

WB_REGISTER_DOMAIN(CrdtDomain)

}  // namespace wb
