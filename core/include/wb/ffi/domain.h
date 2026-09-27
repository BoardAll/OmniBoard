#pragma once

// domain.h — cross-module invocation contract of the core engine.
//
// CONTRACT FILE (Wave 0). The FFI layer (wb.h) forwards every exported
// function into a named *domain handler* using this JSON-in/JSON-out
// interface. Domains are implemented by independent task packages and
// register themselves via static registrars (WB_REGISTER_DOMAIN), so
// package code never includes another package's headers.
//
// Response shape (always a UTF-8 JSON object):
//   success: {"ok":true,  "result":{ ... }}
//   failure: {"ok":false, "error":{"code":"NotFound","message":"..."}}
// Error codes mirror command.schema.json / wb::ErrorCode names.

#include <memory>
#include <string>
#include <vector>

#include "wb/base/error.h"

namespace wb {

class DomainHandler {
 public:
  virtual ~DomainHandler() = default;

  /// Unique domain name, e.g. "board", "page", "element", "render", "theme".
  virtual std::string name() const = 0;

  /// Handles one operation. `op` is the camelCase method name (e.g. "create",
  /// "getDisplayList"); `argsJson` is a UTF-8 JSON object or "{}"/"" when the
  /// operation takes no arguments. Returns the response JSON above.
  /// Must be thread-safe: concurrent invocations on different handles are
  /// allowed; implementations synchronize their own state.
  virtual std::string handle(const std::string& op, const std::string& argsJson) = 0;
};

// --- Registry ---------------------------------------------------------------
// Implemented once by the base/ffi package (task 1.1).

/// Registers (or replaces) a domain handler. Thread-safe.
void registerDomain(std::unique_ptr<DomainHandler> handler);

/// Invokes `domain.op` with `argsJson`. Returns the response JSON; unknown
/// domains/ops produce a {"ok":false,...} response, never throw.
/// Thread-safe.
std::string invokeDomain(const std::string& domain, const std::string& op,
                         const std::string& argsJson);

/// Names of all registered domains (sorted).
std::vector<std::string> listDomains();

/// Helper: build a failure response JSON.
std::string domainError(const std::string& code, const std::string& message);

/// Helper: build a success response JSON from a pre-serialized result object
/// (`resultJson` must be a JSON object, e.g. `{}` when empty).
std::string domainOk(const std::string& resultJson);

struct DomainRegistrar {
  explicit DomainRegistrar(std::unique_ptr<DomainHandler> handler) {
    registerDomain(std::move(handler));
  }
};

}  // namespace wb

/// Registers a domain handler type (default-constructible) at static init time.
/// Usage at file scope of any .cpp in the owning package:
///   WB_REGISTER_DOMAIN(ThemeDomain);
#define WB_REGISTER_DOMAIN(Type)                                    \
  namespace {                                                       \
  const ::wb::DomainRegistrar g_wb_domain_reg_##Type{               \
      std::make_unique<Type>()};                                    \
  }
