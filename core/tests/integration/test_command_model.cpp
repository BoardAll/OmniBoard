// tests/integration/test_command_model.cpp — 集成链路：命令总线 × 文档状态
// （《测试方案设计》§7.1 清单第 1 项）。
//
// 覆盖链路：
//   1. wb_execute_command("element.create") → element.list 状态联动
//      → command.history 计数 → undo 删除元素 → redo 恢复元素。
//   2. element.update 的 undo 恢复旧值 / redo 重放新值。
//   3. 成功 batch 的子命令逐条入撤销栈（undo 一次只回滚最后一条）。
//   4. 失败 batch 的原子回滚 + 历史不新增 + 错误 detail。
//   5. page.delete → undo 恢复页面（含元素）→ page.list 联动。
//   错误路径：无历史时 undo/redo 返回 NotFound。

#include <catch2/catch_test_macros.hpp>

#include <string>

#include "support/test_probe.h"

TEST_CASE("command: element.create undo/redo syncs with document state",
          "[integration][command]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  // 1) 命令总线执行 element.create（显式 id 以便 redo 后断言稳定）。
  const std::string createCmd =
      "{\"type\":\"element.create\",\"params\":{\"pageId\":\"" +
      scene.pageId +
      "\",\"element\":{\"id\":\"cmd-elem-1\",\"type\":\"rect\","
      "\"position\":{\"x\":10,\"y\":20},\"size\":{\"width\":100,"
      "\"height\":50},\"text\":\"节点A\"}}}";
  const std::string response =
      TakeAndFree(wb_execute_command(scene.handle, createCmd.c_str()));
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonString(response, "elementId") == "cmd-elem-1");

  // 2) 文档状态：元素已就位。
  {
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(listed, "count") == 1.0);
    REQUIRE(JsonContains(listed, "cmd-elem-1"));
    REQUIRE(JsonContains(listed, "\"text\":\"节点A\""));
  }

  // 3) 历史：一条可撤销记录、redo 为空。
  {
    const std::string history = TakeAndFree(
        wb_execute_command(scene.handle, "{\"type\":\"command.history\"}"));
    REQUIRE(JsonNumber(history, "undoCount") == 1.0);
    REQUIRE(JsonNumber(history, "redoCount") == 0.0);
    REQUIRE(JsonContains(history, "\"type\":\"element.create\""));
    REQUIRE(JsonBool(history, "undoable", true));
  }

  // 4) undo：create 的逆操作 delete 生效，元素从文档消失。
  {
    const std::string undone = TakeAndFree(
        wb_execute_command(scene.handle, "{\"type\":\"command.undo\"}"));
    REQUIRE(JsonBool(undone, "ok", true));
    REQUIRE(JsonNumber(undone, "undone") == 1.0);
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(listed, "count") == 0.0);
  }

  // 5) redo：重放原命令，元素恢复且 id 稳定。
  {
    const std::string redone = TakeAndFree(
        wb_execute_command(scene.handle, "{\"type\":\"command.redo\"}"));
    REQUIRE(JsonBool(redone, "ok", true));
    REQUIRE(JsonNumber(redone, "redone") == 1.0);
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(listed, "count") == 1.0);
    REQUIRE(JsonContains(listed, "cmd-elem-1"));
  }

  // 6) 再 undo 后历史 redo 恢复可用。
  {
    TakeAndFree(wb_execute_command(scene.handle, "{\"type\":\"command.undo\"}"));
    const std::string history = TakeAndFree(
        wb_execute_command(scene.handle, "{\"type\":\"command.history\"}"));
    REQUIRE(JsonNumber(history, "undoCount") == 0.0);
    REQUIRE(JsonNumber(history, "redoCount") == 1.0);
  }
}

TEST_CASE("command: element.update undo restores old value, redo reapplies",
          "[integration][command]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  const std::string elementId =
      CreateElement(scene.pageId, RectElement(0, 0, 50, 50, "旧值"));
  REQUIRE_FALSE(elementId.empty());

  // 通过命令总线更新文本。
  const std::string updateCmd =
      "{\"type\":\"element.update\",\"params\":{\"elementId\":\"" +
      elementId + "\",\"patch\":{\"text\":\"新值\"}}}";
  const std::string updated =
      TakeAndFree(wb_execute_command(scene.handle, updateCmd.c_str()));
  REQUIRE(JsonBool(updated, "ok", true));
  {
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonContains(listed, "\"text\":\"新值\""));
    REQUIRE_FALSE(JsonContains(listed, "\"text\":\"旧值\""));
  }

  // undo：previous 逆操作把旧值写回。
  const std::string undone = TakeAndFree(
      wb_execute_command(scene.handle, "{\"type\":\"command.undo\"}"));
  REQUIRE(JsonBool(undone, "ok", true));
  {
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonContains(listed, "\"text\":\"旧值\""));
    REQUIRE_FALSE(JsonContains(listed, "\"text\":\"新值\""));
  }

  // redo：重新应用 patch。
  const std::string redone = TakeAndFree(
      wb_execute_command(scene.handle, "{\"type\":\"command.redo\"}"));
  REQUIRE(JsonBool(redone, "ok", true));
  {
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonContains(listed, "\"text\":\"新值\""));
  }
}

TEST_CASE("command: successful batch pushes each sub-command to undo stack", "[integration][command]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  const std::string batch =
      "{\"type\":\"batch\",\"params\":{\"ops\":["
      "{\"type\":\"element.create\",\"params\":{\"pageId\":\"" +
      scene.pageId +
      "\",\"element\":{\"id\":\"batch-a\",\"type\":\"rect\","
      "\"position\":{\"x\":0,\"y\":0},\"size\":{\"width\":10,\"height\":10}}}},"
      "{\"type\":\"element.create\",\"params\":{\"pageId\":\"" +
      scene.pageId +
      "\",\"element\":{\"id\":\"batch-b\",\"type\":\"ellipse\","
      "\"position\":{\"x\":20,\"y\":0},\"size\":{\"width\":10,\"height\":10}}}}"
      "]}}";
  const std::string response =
      TakeAndFree(wb_execute_command(scene.handle, batch.c_str()));
  REQUIRE(JsonBool(response, "ok", true));
  REQUIRE(JsonNumber(response, "executed") == 2.0);
  {
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(listed, "count") == 2.0);
  }

  // 历史含两条记录。
  {
    const std::string history = TakeAndFree(
        wb_execute_command(scene.handle, "{\"type\":\"command.history\"}"));
    REQUIRE(JsonNumber(history, "undoCount") == 2.0);
  }

  // undo 一次只回滚最后一条（batch-b 先消失）。
  const std::string undone1 = TakeAndFree(
      wb_execute_command(scene.handle, "{\"type\":\"command.undo\"}"));
  REQUIRE(JsonBool(undone1, "ok", true));
  {
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(listed, "count") == 1.0);
    REQUIRE(JsonContains(listed, "batch-a"));
    REQUIRE_FALSE(JsonContains(listed, "batch-b"));
  }

  // 第二次 undo 回滚 batch-a。
  const std::string undone2 = TakeAndFree(
      wb_execute_command(scene.handle, "{\"type\":\"command.undo\"}"));
  REQUIRE(JsonBool(undone2, "ok", true));
  {
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(listed, "count") == 0.0);
  }
}

TEST_CASE("command: failed batch rolls back atomically without history", "[integration][command]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  // 第二个子命令指向不存在的页面 → 整体失败并回滚第一个 create。
  const std::string batch =
      "{\"type\":\"batch\",\"params\":{\"ops\":["
      "{\"type\":\"element.create\",\"params\":{\"pageId\":\"" +
      scene.pageId +
      "\",\"element\":{\"id\":\"rollback-1\",\"type\":\"rect\","
      "\"position\":{\"x\":0,\"y\":0},\"size\":{\"width\":10,\"height\":10}}}},"
      "{\"type\":\"element.create\",\"params\":{\"pageId\":\"no-such-page\","
      "\"element\":{\"type\":\"rect\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":10,\"height\":10}}}}"
      "]}}";
  const std::string response =
      TakeAndFree(wb_execute_command(scene.handle, batch.c_str()));
  REQUIRE(JsonBool(response, "ok", false));
  REQUIRE(JsonContains(response, "rolled back"));
  REQUIRE(JsonNumber(response, "failedIndex") == 1.0);

  // 第一个元素已被回滚删除。
  {
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(listed, "count") == 0.0);
  }

  // 失败 batch 不产生撤销记录。
  {
    const std::string history = TakeAndFree(
        wb_execute_command(scene.handle, "{\"type\":\"command.history\"}"));
    REQUIRE(JsonNumber(history, "undoCount") == 0.0);
  }
}

TEST_CASE("command: page.delete undo restores page and element ownership",
          "[integration][command]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  // 默认页放一个元素；再建第二页并放入元素。
  REQUIRE_FALSE(
      CreateElement(scene.pageId, RectElement(0, 0, 30, 30, "first")).empty());
  const std::string page2Response = TakeAndFree(
      wb_page_create(scene.boardId.c_str(), "{\"name\":\"第二页\"}"));
  REQUIRE(JsonBool(page2Response, "ok", true));
  const std::string page2 = JsonString(page2Response, "pageId");
  REQUIRE_FALSE(page2.empty());
  REQUIRE_FALSE(
      CreateElement(page2, RectElement(0, 0, 30, 30, "second")).empty());

  // 通过命令总线删除第二页（deleted 携带完整页面快照）。
  const std::string deleteCmd = "{\"type\":\"page.delete\",\"params\":{\"pageId\":\"" +
                                page2 + "\"}}";
  const std::string deleted =
      TakeAndFree(wb_execute_command(scene.handle, deleteCmd.c_str()));
  REQUIRE(JsonBool(deleted, "ok", true));
  REQUIRE(JsonContains(deleted, "\"deleted\""));
  REQUIRE(JsonContains(deleted, "second"));
  {
    const std::string pages =
        TakeAndFree(wb_page_list(scene.boardId.c_str()));
    REQUIRE(JsonNumber(pages, "count") == 1.0);
  }

  // undo：page.create 逆操作恢复页面（含元素快照）。
  const std::string undone = TakeAndFree(
      wb_execute_command(scene.handle, "{\"type\":\"command.undo\"}"));
  REQUIRE(JsonBool(undone, "ok", true));
  {
    const std::string pages =
        TakeAndFree(wb_page_list(scene.boardId.c_str()));
    REQUIRE(JsonNumber(pages, "count") == 2.0);
    // 两页各含 1 个元素（"elementCount":1 出现 2 次）。
    REQUIRE(CountOccurrences(pages, "\"elementCount\":1") == 2);
  }
}

TEST_CASE("command: empty history undo/redo returns NotFound",
          "[integration][command]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  const std::string undone = TakeAndFree(
      wb_execute_command(scene.handle, "{\"type\":\"command.undo\"}"));
  REQUIRE(JsonBool(undone, "ok", false));
  REQUIRE(JsonContains(undone, "nothing to undo"));

  const std::string redone = TakeAndFree(
      wb_execute_command(scene.handle, "{\"type\":\"command.redo\"}"));
  REQUIRE(JsonBool(redone, "ok", false));
  REQUIRE(JsonContains(redone, "nothing to redo"));
}
