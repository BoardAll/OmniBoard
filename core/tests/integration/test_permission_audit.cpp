// tests/integration/test_permission_audit.cpp — 集成链路：权限校验 × 审计记录
// （《测试方案设计》§7.1 清单第 7 项）。
//
// 覆盖链路：
//   1. 权限校验状态机：未授权拒绝 → grant read → 校验通过 → grant write
//      升级 → （不降级）→ revoke 后回落，每步与 level/allowed 联动。
//   2. 审计记录联动：permission/工具操作经 audit.log 落库（audit-N 编号）
//      → query 按 userId/toolId/fromAI/limit 过滤 → export 输出 JSONL
//      文件（行数与内容回读校验）。
//   3. ACL 层次语义：admin 隐含全部低权限请求、列表过滤、grant 取最大、
//      revoke 幂等、未知权限名拒绝。
//
// 注：permission / audit 均为进程级单例；用例内以唯一 userId/boardId
// 隔离，审计用例开头 clear 以保证计数稳定（id 序号不清零，故按前缀
// 断言）。wb_permission_check 走 FFI，grant/revoke/list/levels 走
// invokeDomain。

#include <catch2/catch_test_macros.hpp>

#include <cstdio>
#include <fstream>
#include <string>

#include "support/test_probe.h"

TEST_CASE("permission and audit: check state machine and audit export",
          "[integration][permission][audit]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  const std::string user = "it-user-alice";
  const std::string denied =
      TakeAndFree(wb_permission_check(user.c_str(), scene.boardId.c_str(), "read"));
  REQUIRE(JsonBool(denied, "ok", true));
  REQUIRE(JsonBool(denied, "allowed", false));
  REQUIRE(JsonString(denied, "level") == "none");

  // 1) grant read → read 通过、write 拒绝（层次推导）。
  const std::string grantRead = wb::invokeDomain(
      "permission", "grant",
      "{\"userId\":\"" + user + "\",\"boardId\":\"" + scene.boardId +
          "\",\"permission\":\"read\"}");
  REQUIRE(JsonBool(grantRead, "granted", true));
  REQUIRE(JsonBool(grantRead, "raised", true));
  REQUIRE(JsonString(grantRead, "level") == "read");
  const std::string readAllowed =
      TakeAndFree(wb_permission_check(user.c_str(), scene.boardId.c_str(), "read"));
  REQUIRE(JsonBool(readAllowed, "allowed", true));
  REQUIRE(JsonString(readAllowed, "level") == "read");
  const std::string writeDenied = TakeAndFree(
      wb_permission_check(user.c_str(), scene.boardId.c_str(), "write"));
  REQUIRE(JsonBool(writeDenied, "allowed", false));

  // 2) grant write 升级；再次 grant read 不降级。
  const std::string grantWrite = wb::invokeDomain(
      "permission", "grant",
      "{\"userId\":\"" + user + "\",\"boardId\":\"" + scene.boardId +
          "\",\"permission\":\"write\"}");
  REQUIRE(JsonBool(grantWrite, "raised", true));
  REQUIRE(JsonString(grantWrite, "level") == "write");
  const std::string grantReadAgain = wb::invokeDomain(
      "permission", "grant",
      "{\"userId\":\"" + user + "\",\"boardId\":\"" + scene.boardId +
          "\",\"permission\":\"read\"}");
  REQUIRE(JsonBool(grantReadAgain, "raised", false));
  REQUIRE(JsonString(grantReadAgain, "level") == "write");
  const std::string writeAllowed = TakeAndFree(
      wb_permission_check(user.c_str(), scene.boardId.c_str(), "write"));
  REQUIRE(JsonBool(writeAllowed, "allowed", true));

  // 3) revoke write 移除授权（此刻整条授权被移除），再 revoke 为幂等空操作。
  const std::string revoked = wb::invokeDomain(
      "permission", "revoke",
      "{\"userId\":\"" + user + "\",\"boardId\":\"" + scene.boardId +
          "\",\"permission\":\"write\"}");
  REQUIRE(JsonBool(revoked, "revoked", true));
  const std::string afterRevoke =
      TakeAndFree(wb_permission_check(user.c_str(), scene.boardId.c_str(), "read"));
  REQUIRE(JsonBool(afterRevoke, "allowed", false));
  REQUIRE(JsonString(afterRevoke, "level") == "none");
  const std::string revokeAgain = wb::invokeDomain(
      "permission", "revoke",
      "{\"userId\":\"" + user + "\",\"boardId\":\"" + scene.boardId +
          "\",\"permission\":\"write\"}");
  REQUIRE(JsonBool(revokeAgain, "revoked", false));

  // 4) 审计链路：清空后写入 4 条记录（含 AI 来源与另一用户）。
  REQUIRE(JsonBool(wb::invokeDomain("audit", "clear", "{}"), "ok", true));
  const std::string log1 = wb::invokeDomain(
      "audit", "log",
      "{\"entry\":{\"userId\":\"" + user +
          "\",\"toolId\":\"permission.grant\",\"fromAI\":false}}");
  REQUIRE(JsonBool(log1, "ok", true));
  REQUIRE(JsonContains(log1, "\"id\":\"audit-"));
  REQUIRE(JsonNumber(log1, "count") == 1.0);
  const std::string log2 = wb::invokeDomain(
      "audit", "log",
      "{\"entry\":{\"userId\":\"" + user +
          "\",\"toolId\":\"permission.check\",\"fromAI\":false}}");
  REQUIRE(JsonNumber(log2, "count") == 2.0);
  const std::string log3 = wb::invokeDomain(
      "audit", "log",
      "{\"entry\":{\"userId\":\"" + user +
          "\",\"toolId\":\"element.create\",\"fromAI\":true}}");
  REQUIRE(JsonNumber(log3, "count") == 3.0);
  const std::string log4 = wb::invokeDomain(
      "audit", "log",
      "{\"entry\":{\"userId\":\"it-user-bob\",\"toolId\":\"permission.grant\","
      "\"fromAI\":false}}");
  REQUIRE(JsonNumber(log4, "count") == 4.0);

  // 缺少 userId/toolId 的条目被拒。
  const std::string badLog =
      wb::invokeDomain("audit", "log", "{\"entry\":{\"userId\":\"" + user + "\"}}");
  REQUIRE(JsonBool(badLog, "ok", false));
  REQUIRE(JsonContains(badLog, "InvalidArgument"));

  // 5) query 过滤联动。
  const std::string byUser = TakeAndFree(
      wb_audit_query(("{\"userId\":\"" + user + "\"}").c_str()));
  REQUIRE(JsonBool(byUser, "ok", true));
  REQUIRE(JsonNumber(byUser, "count") == 3.0);
  REQUIRE(JsonContains(byUser, "element.create"));
  REQUIRE_FALSE(JsonContains(byUser, "it-user-bob"));

  const std::string byTool =
      TakeAndFree(wb_audit_query("{\"toolId\":\"permission.grant\"}"));
  REQUIRE(JsonNumber(byTool, "count") == 2.0);

  const std::string byAi =
      TakeAndFree(wb_audit_query("{\"fromAI\":true}"));
  REQUIRE(JsonNumber(byAi, "count") == 1.0);
  REQUIRE(JsonContains(byAi, "element.create"));

  const std::string combined = TakeAndFree(wb_audit_query(
      ("{\"userId\":\"" + user + "\",\"toolId\":\"element.create\"}").c_str()));
  REQUIRE(JsonNumber(combined, "count") == 1.0);
  const std::string limited =
      TakeAndFree(wb_audit_query(("{\"userId\":\"" + user + "\",\"limit\":2}").c_str()));
  REQUIRE(JsonNumber(limited, "count") == 2.0);

  // 6) export：JSONL 落盘，行数与内容回读校验。
  const std::string path = "wb_audit_it_export.jsonl";
  const std::string exported = TakeAndFree(wb_audit_export(path.c_str()));
  REQUIRE(JsonBool(exported, "ok", true));
  REQUIRE(JsonNumber(exported, "exported") == 4.0);
  REQUIRE(JsonNumber(exported, "bytes") > 0.0);
  REQUIRE(JsonString(exported, "path") == path);
  {
    std::ifstream input(path, std::ios::binary);
    REQUIRE(input.is_open());
    int lines = 0;
    bool allJsonLines = true;
    std::string line;
    while (std::getline(input, line)) {
      if (line.empty()) continue;
      ++lines;
      if (line.front() != '{' ||
          line.find("\"id\":\"audit-") == std::string::npos) {
        allJsonLines = false;
      }
    }
    REQUIRE(lines == 4);
    REQUIRE(allJsonLines);
  }
  std::remove(path.c_str());
}

TEST_CASE("permission and audit: ACL levels, list and revoke semantics",
          "[integration][permission][audit]") {
  const std::string boardId = "it-acl-board-2";
  const std::string admin = "it-user-admin-2";
  const std::string editor = "it-user-editor-2";

  // 1) admin 为最高级：隐含所有低权限请求。
  REQUIRE(JsonBool(wb::invokeDomain(
                       "permission", "grant",
                       "{\"userId\":\"" + admin + "\",\"boardId\":\"" +
                           boardId + "\",\"permission\":\"admin\"}"),
                   "ok", true));
  for (const char* perm : {"read", "write", "share", "admin"}) {
    const std::string checked =
        TakeAndFree(wb_permission_check(admin.c_str(), boardId.c_str(), perm));
    REQUIRE(JsonBool(checked, "allowed", true));
  }

  // 2) editor 仅 write：share 被拒。
  REQUIRE(JsonBool(wb::invokeDomain(
                       "permission", "grant",
                       "{\"userId\":\"" + editor + "\",\"boardId\":\"" +
                           boardId + "\",\"permission\":\"write\"}"),
                   "ok", true));
  const std::string shareDenied =
      TakeAndFree(wb_permission_check(editor.c_str(), boardId.c_str(), "share"));
  REQUIRE(JsonBool(shareDenied, "allowed", false));
  REQUIRE(JsonString(shareDenied, "level") == "write");

  // 3) list 按 boardId 过滤：恰好两条授权、等级正确。
  const std::string listed = wb::invokeDomain(
      "permission", "list", "{\"boardId\":\"" + boardId + "\"}");
  REQUIRE(JsonBool(listed, "ok", true));
  REQUIRE(JsonNumber(listed, "count") == 2.0);
  REQUIRE(JsonContains(listed, "\"level\":\"admin\""));
  REQUIRE(JsonContains(listed, "\"level\":\"write\""));
  REQUIRE(JsonContains(listed, admin));
  REQUIRE(JsonContains(listed, editor));

  // 4) levels 层次表：read=1 < write=2 < share=3 < admin=4。
  const std::string levels = wb::invokeDomain("permission", "levels", "{}");
  REQUIRE(JsonBool(levels, "ok", true));
  REQUIRE(JsonContains(levels, "\"name\":\"admin\",\"value\":4"));
  REQUIRE(JsonContains(levels, "\"name\":\"read\",\"value\":1"));

  // 5) grant 不降级；revoke 高于持有点等级的请求为空操作。
  const std::string lowerGrant = wb::invokeDomain(
      "permission", "grant",
      "{\"userId\":\"" + editor + "\",\"boardId\":\"" + boardId +
          "\",\"permission\":\"read\"}");
  REQUIRE(JsonBool(lowerGrant, "raised", false));
  REQUIRE(JsonString(lowerGrant, "level") == "write");
  const std::string highRevoke = wb::invokeDomain(
      "permission", "revoke",
      "{\"userId\":\"" + editor + "\",\"boardId\":\"" + boardId +
          "\",\"permission\":\"share\"}");
  REQUIRE(JsonBool(highRevoke, "revoked", false));

  // 6) revoke 持有点等级 → 移除；再次 revoke 幂等。
  const std::string revoked = wb::invokeDomain(
      "permission", "revoke",
      "{\"userId\":\"" + editor + "\",\"boardId\":\"" + boardId +
          "\",\"permission\":\"write\"}");
  REQUIRE(JsonBool(revoked, "revoked", true));
  const std::string after = wb::invokeDomain(
      "permission", "list", "{\"boardId\":\"" + boardId + "\"}");
  REQUIRE(JsonNumber(after, "count") == 1.0);
  const std::string again = wb::invokeDomain(
      "permission", "revoke",
      "{\"userId\":\"" + editor + "\",\"boardId\":\"" + boardId +
          "\",\"permission\":\"write\"}");
  REQUIRE(JsonBool(again, "revoked", false));

  // 7) 未知权限名：InvalidArgument。
  const std::string unknown = wb::invokeDomain(
      "permission", "grant",
      "{\"userId\":\"" + editor + "\",\"boardId\":\"" + boardId +
          "\",\"permission\":\"superuser\"}");
  REQUIRE(JsonBool(unknown, "ok", false));
  REQUIRE(JsonContains(unknown, "unknown permission"));
}
