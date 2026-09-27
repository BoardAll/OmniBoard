// ffi/domain_registry.cpp — cross-module domain registry (task package 1.1).
// Owns: core/src/ffi. See wb/ffi/domain.h for the contract.

#include "wb/ffi/domain.h"

#include <map>
#include <memory>
#include <mutex>
#include <shared_mutex>

#include <nlohmann/json.hpp>

namespace wb {
namespace {

std::map<std::string, std::shared_ptr<DomainHandler>>& Registry() {
  static std::map<std::string, std::shared_ptr<DomainHandler>> registry;
  return registry;
}

std::shared_mutex& RegistryMutex() {
  static std::shared_mutex mutex;
  return mutex;
}

}  // namespace

void registerDomain(std::unique_ptr<DomainHandler> handler) {
  if (handler == nullptr) {
    return;
  }
  const std::string name = handler->name();
  if (name.empty()) {
    return;
  }
  std::unique_lock<std::shared_mutex> lock(RegistryMutex());
  Registry()[name] = std::shared_ptr<DomainHandler>(std::move(handler));
}

std::string invokeDomain(const std::string& domain, const std::string& op,
                         const std::string& argsJson) {
  if (domain.empty()) {
    return domainError("InvalidArgument", "domain name must not be empty");
  }
  std::shared_ptr<DomainHandler> handler;
  {
    std::shared_lock<std::shared_mutex> lock(RegistryMutex());
    const auto it = Registry().find(domain);
    if (it == Registry().end()) {
      return domainError("NotFound", "unknown domain: " + domain);
    }
    handler = it->second;  // keep alive outside the lock (nested calls allowed)
  }
  if (handler == nullptr) {
    return domainError("InternalError", "domain handler is null: " + domain);
  }
  try {
    return handler->handle(op, argsJson);
  } catch (const std::exception& e) {
    return domainError("InternalError", std::string("domain '") + domain + "." + op +
                                            "' threw: " + e.what());
  } catch (...) {
    return domainError("InternalError",
                       std::string("domain '") + domain + "." + op +
                           "' threw a non-standard exception");
  }
}

std::vector<std::string> listDomains() {
  std::vector<std::string> names;
  std::shared_lock<std::shared_mutex> lock(RegistryMutex());
  names.reserve(Registry().size());
  for (const auto& entry : Registry()) {
    names.push_back(entry.first);
  }
  return names;  // std::map iterates in sorted order
}

std::string domainError(const std::string& code, const std::string& message) {
  nlohmann::json response;
  response["ok"] = false;
  response["error"] = {{"code", code}, {"message", message}};
  return response.dump();
}

std::string domainOk(const std::string& resultJson) {
  nlohmann::json result = nlohmann::json::object();
  if (!resultJson.empty()) {
    result = nlohmann::json::parse(resultJson, nullptr, false);
    if (result.is_discarded()) {
      return domainError("InternalError", "domainOk: result is not valid JSON");
    }
  }
  nlohmann::json response;
  response["ok"] = true;
  response["result"] = std::move(result);
  return response.dump();
}

}  // namespace wb
