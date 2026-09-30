// tests/unit/ffi/ffi_collab_symbols_test.cpp — M1 collaboration data-plane
// symbols (7 thin forwards; decision D-A). Tags: [ffi]
//
// Contract level only. The five sync symbols are asserted envelope-wise so
// this suite stays green while the sync-domain implementation lands in
// parallel (unimplemented op -> NotFound, implemented op -> InvalidArgument
// or a real result; every assertion below holds in both worlds). The two
// crdt symbols target the already-frozen crdt domain, which additionally
// pins the FFI argument routing (docId / operation keys).

#include <catch2/catch_test_macros.hpp>

#include <string>

#include "wb/wb.h"

namespace {

bool Contains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

bool HasOkField(const std::string& response) {
  return Contains(response, "\"ok\":true") || Contains(response, "\"ok\":false");
}

/// Contract probe: non-null heap copy that is a JSON object carrying the
/// "ok" flag; the copy is released through wb_free() by the caller.
void RequireEnvelope(const std::string& response) {
  REQUIRE_FALSE(response.empty());
  REQUIRE(response.front() == '{');
  REQUIRE(response.back() == '}');
  REQUIRE(HasOkField(response));
}

std::string TakeAndFree(const char* owned) {
  REQUIRE(owned != nullptr);
  std::string copy(owned);
  wb_free(owned);
  return copy;
}

}  // namespace

TEST_CASE("sync collaboration symbols return JSON envelopes", "[ffi]") {
  RequireEnvelope(TakeAndFree(wb_sync_join("board-bridge", "page-bridge")));
  RequireEnvelope(TakeAndFree(wb_sync_join("board-bridge", nullptr)));
  RequireEnvelope(TakeAndFree(wb_sync_send_operation("{\"key\":\"k\",\"value\":1}")));
  RequireEnvelope(TakeAndFree(wb_sync_flush()));
  RequireEnvelope(TakeAndFree(wb_sync_events()));
  RequireEnvelope(TakeAndFree(wb_sync_send_preview("{\"kind\":\"transform\"}")));
}

TEST_CASE("crdt collaboration symbols return JSON envelopes", "[ffi]") {
  RequireEnvelope(TakeAndFree(wb_crdt_create("ffi-bridge-doc", "ffi-bridge-actor")));
  RequireEnvelope(TakeAndFree(
      wb_crdt_apply_local("ffi-bridge-doc", "{\"key\":\"k\",\"value\":1}")));
}

TEST_CASE("sync collaboration symbols reject null or malformed input", "[ffi]") {
  // Both worlds agree here: NotFound while the op is unimplemented,
  // InvalidArgument once it is (missing boardId / payload), never ok:true.
  REQUIRE(Contains(TakeAndFree(wb_sync_join(nullptr, nullptr)), "\"ok\":false"));
  REQUIRE(Contains(TakeAndFree(wb_sync_send_operation(nullptr)), "\"ok\":false"));
  REQUIRE(Contains(TakeAndFree(wb_sync_send_operation("{not-json")), "\"ok\":false"));
  REQUIRE(Contains(TakeAndFree(wb_sync_send_preview(nullptr)), "\"ok\":false"));
  REQUIRE(Contains(TakeAndFree(wb_sync_send_preview("{not-json")), "\"ok\":false"));
}

TEST_CASE("crdt apply_local routes into the frozen crdt domain", "[ffi]") {
  // Frozen crdt semantics: a created document accepts a local op and the
  // result echoes the register key; an unknown document is an error.
  REQUIRE(Contains(TakeAndFree(wb_crdt_create("ffi-bridge-route", "actor-route")),
                   "\"ok\":true"));
  const std::string applied = TakeAndFree(
      wb_crdt_apply_local("ffi-bridge-route", "{\"key\":\"k\",\"value\":1}"));
  REQUIRE(Contains(applied, "\"ok\":true"));
  REQUIRE(Contains(applied, "\"key\":\"k\""));

  REQUIRE(Contains(TakeAndFree(wb_crdt_apply_local(
                       "ffi-bridge-missing", "{\"key\":\"k\",\"value\":1}")),
                   "\"ok\":false"));
}

TEST_CASE("wb_sync_events hands off memory released by wb_free", "[ffi]") {
  // Output-type symbol: each call returns an independent heap copy that the
  // host releases with wb_free() (no crash, no leak, no double free).
  const char* events = wb_sync_events();
  REQUIRE(events != nullptr);
  const std::string first(events);
  wb_free(events);
  REQUIRE(HasOkField(first));

  const char* again = wb_sync_events();
  REQUIRE(again != nullptr);
  wb_free(again);
  wb_free(nullptr);  // wb_free stays null-safe for this path too.
}
