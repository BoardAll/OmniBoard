#pragma once

// facade/facade.h — thin C++ convenience layer over the domain mediator
// (task package 1.2). Owns: core/src/facade.
//
// The facade adds nothing but ergonomics: every helper is a one-liner around
// invokeDomain(), returning the raw response JSON. Hosts that need typed
// models use core_dart (Wave 2); internal C++ callers use this header.

#include <string>

#include "wb/base/types.h"

namespace wb::facade {

/// Raw JSON-in/JSON-out call. Never throws.
std::string call(const std::string& domain, const std::string& op,
                 const std::string& argsJson = "{}");

/// True when a response JSON has "ok":true.
bool isOk(const std::string& response);

/// Creates a board; returns the handle or kInvalidHandle on failure.
Handle createBoard(const std::string& json = "{}");

std::string boardGet(Handle handle);
std::string boardDestroy(Handle handle);

std::string pageList(const BoardId& boardId);
std::string pageCreate(const BoardId& boardId, const std::string& pageJson = "{}");

std::string elementCreate(const PageId& pageId, const std::string& elementJson);
std::string elementList(const PageId& pageId);

std::string executeCommand(Handle handle, const std::string& commandJson);
std::string executeTool(const ToolId& toolId, const std::string& argsJson = "{}");

}  // namespace wb::facade
