#pragma once

// wb::base — error codes and Result<T>. Contract file (Wave 0).
// Per design doc《C++ 核心引擎接口设计》§4.2.

#include <string>
#include <utility>

namespace wb {

enum class ErrorCode {
  Ok = 0,
  InvalidArgument,
  NotFound,
  PermissionDenied,
  Conflict,
  InternalError,
  NotSupported,
  Timeout,
  Cancelled,
  ResourceExhausted,
};

struct Error {
  ErrorCode code = ErrorCode::Ok;
  std::string message;
  std::string detail;

  bool ok() const { return code == ErrorCode::Ok; }

  static Error none() { return Error{}; }

  static Error make(ErrorCode c, std::string msg, std::string det = "") {
    return Error{c, std::move(msg), std::move(det)};
  }
};

template <typename T>
struct Result {
  T value{};
  Error error;

  bool ok() const { return error.code == ErrorCode::Ok; }

  static Result success(T v) { return Result{std::move(v), Error{}}; }
  static Result failure(ErrorCode c, std::string msg, std::string det = "") {
    return Result{T{}, Error::make(c, std::move(msg), std::move(det))};
  }
};

template <>
struct Result<void> {
  Error error;

  bool ok() const { return error.code == ErrorCode::Ok; }

  static Result success() { return Result{}; }
  static Result failure(ErrorCode c, std::string msg, std::string det = "") {
    return Result{Error::make(c, std::move(msg), std::move(det))};
  }
};

}  // namespace wb
