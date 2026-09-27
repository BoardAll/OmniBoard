// tests/integration/test_page_element.cpp — 集成链路：页面管理 × 元素归属
// （《测试方案设计》§7.1 清单第 2 项）。
//
// 覆盖链路：
//   1. 多页元素归属：page.create → 各页 element.create → 列表互不串页，
//      page.list 的 elementCount 与元素数联动。
//   2. page.duplicate 深拷贝：新元素 id 重映射、内容保留、" 副本" 命名、
//      副本修改不影响原页（双向隔离）。
//   3. element.delete 级联删除连线元素（deletedConnectorIds）。
//   4. 页面锁定后元素写操作（create/update/delete）返回 Conflict，解锁恢复。
//   5. 页面 hide 与 page.list / element 数据联动。
//   6. 最后一页删除保护（Conflict）。

#include <catch2/catch_test_macros.hpp>

#include <string>

#include "support/test_probe.h"

TEST_CASE("page element: multi-page ownership and elementCount",
          "[integration][page][element]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  // 默认页 1 个元素 + 新建页 2 个元素。
  REQUIRE_FALSE(
      CreateElement(scene.pageId, RectElement(0, 0, 10, 10, "p1-a")).empty());
  const std::string page2Response =
      TakeAndFree(wb_page_create(scene.boardId.c_str(), "{}"));
  REQUIRE(JsonBool(page2Response, "ok", true));
  const std::string page2 = JsonString(page2Response, "pageId");
  REQUIRE_FALSE(page2.empty());
  REQUIRE_FALSE(
      CreateElement(page2, RectElement(0, 0, 10, 10, "p2-a")).empty());
  REQUIRE_FALSE(
      CreateElement(page2, RectElement(20, 0, 10, 10, "p2-b")).empty());

  // 各页元素列表互不串页。
  {
    const std::string p1List =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(p1List, "count") == 1.0);
    REQUIRE(JsonContains(p1List, "p1-a"));
    REQUIRE_FALSE(JsonContains(p1List, "p2-a"));

    const std::string p2List = TakeAndFree(wb_element_list(page2.c_str()));
    REQUIRE(JsonNumber(p2List, "count") == 2.0);
    REQUIRE(JsonContains(p2List, "p2-a"));
    REQUIRE(JsonContains(p2List, "p2-b"));
    REQUIRE_FALSE(JsonContains(p2List, "p1-a"));
  }

  // page.list 的 elementCount 与元素数联动（页1=1、页2=2）。
  {
    const std::string pages =
        TakeAndFree(wb_page_list(scene.boardId.c_str()));
    REQUIRE(JsonNumber(pages, "count") == 2.0);
    REQUIRE(CountOccurrences(pages, "\"elementCount\":1") == 1);
    REQUIRE(CountOccurrences(pages, "\"elementCount\":2") == 1);
  }
}

TEST_CASE("page element: duplicate remaps ids and isolates pages",
          "[integration][page][element]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  const std::string originalId =
      CreateElement(scene.pageId, RectElement(5, 5, 40, 40, "原始"));
  REQUIRE_FALSE(originalId.empty());

  const std::string duplicated =
      TakeAndFree(wb_page_duplicate(scene.pageId.c_str()));
  REQUIRE(JsonBool(duplicated, "ok", true));
  const std::string copyPageId = JsonString(duplicated, "pageId");
  REQUIRE_FALSE(copyPageId.empty());
  REQUIRE(JsonContains(duplicated, "副本"));

  // 副本页：1 个元素、内容相同、id 已重映射、pageId 指向副本页。
  const std::string copyList = TakeAndFree(wb_element_list(copyPageId.c_str()));
  REQUIRE(JsonNumber(copyList, "count") == 1.0);
  REQUIRE(JsonContains(copyList, "原始"));
  REQUIRE_FALSE(JsonContains(copyList, originalId));
  REQUIRE(JsonContains(copyList, copyPageId));
  const std::string copiedId = JsonStringAfter(copyList, "id", "\"elements\"");
  REQUIRE_FALSE(copiedId.empty());
  REQUIRE(copiedId != originalId);

  // 修改副本中的元素：原页不变（双向隔离）。
  const std::string patch = "{\"text\":\"副本被改\"}";
  const std::string updated =
      TakeAndFree(wb_element_update(copiedId.c_str(), patch.c_str()));
  REQUIRE(JsonBool(updated, "ok", true));

  const std::string originalList =
      TakeAndFree(wb_element_list(scene.pageId.c_str()));
  REQUIRE(JsonContains(originalList, "\"text\":\"原始\""));
  REQUIRE_FALSE(JsonContains(originalList, "副本被改"));
  const std::string copyListAfter =
      TakeAndFree(wb_element_list(copyPageId.c_str()));
  REQUIRE(JsonContains(copyListAfter, "副本被改"));
}

TEST_CASE("page element: deleting endpoint cascades connector element",
          "[integration][page][element]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  const std::string nodeA = CreateElement(scene.pageId, RectElement(0, 0, 20, 20, "A"));
  const std::string nodeB = CreateElement(scene.pageId, RectElement(100, 0, 20, 20, "B"));
  REQUIRE_FALSE(nodeA.empty());
  REQUIRE_FALSE(nodeB.empty());

  const std::string connectorJson =
      "{\"id\":\"conn-1\",\"type\":\"connector\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":100,\"height\":0},\"data\":{\"fromElementId\":\"" +
      nodeA + "\",\"toElementId\":\"" + nodeB + "\"}}";
  REQUIRE_FALSE(CreateElement(scene.pageId, connectorJson).empty());
  {
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(listed, "count") == 3.0);
    REQUIRE(JsonContains(listed, "conn-1"));
  }

  // 删除端点 A：连线被级联删除并出现在 deletedConnectorIds 中。
  const std::string deleted = TakeAndFree(wb_element_delete(nodeA.c_str()));
  REQUIRE(JsonBool(deleted, "ok", true));
  REQUIRE(JsonContains(deleted, "conn-1"));
  REQUIRE(JsonArrayLength(deleted, "deletedConnectorIds") == 1);
  {
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(listed, "count") == 1.0);
    REQUIRE(JsonContains(listed, nodeB));
    REQUIRE_FALSE(JsonContains(listed, "conn-1"));
  }
}

TEST_CASE("page element: locked page rejects writes, unlock restores",
          "[integration][page][element]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  const std::string elementId =
      CreateElement(scene.pageId, RectElement(0, 0, 10, 10, "locked-test"));
  REQUIRE_FALSE(elementId.empty());

  CHECK(JsonBool(TakeAndFree(wb_page_lock(scene.pageId.c_str(), 1)), "ok", true));

  // 锁定期间 create / update / delete 全部 Conflict。
  {
    const std::string created = TakeAndFree(
        wb_element_create(scene.pageId.c_str(), RectElement(0, 0, 5, 5).c_str()));
    REQUIRE(JsonBool(created, "ok", false));
    REQUIRE(JsonContains(created, "locked"));

    const std::string updated = TakeAndFree(
        wb_element_update(elementId.c_str(), "{\"text\":\"blocked\"}"));
    REQUIRE(JsonBool(updated, "ok", false));
    REQUIRE(JsonContains(updated, "locked"));

    const std::string deleted = TakeAndFree(wb_element_delete(elementId.c_str()));
    REQUIRE(JsonBool(deleted, "ok", false));
    REQUIRE(JsonContains(deleted, "locked"));
  }

  // 锁定不改变元素数据。
  {
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(listed, "count") == 1.0);
    REQUIRE_FALSE(JsonContains(listed, "blocked"));
  }

  // 解锁后写操作恢复。
  CHECK(JsonBool(TakeAndFree(wb_page_lock(scene.pageId.c_str(), 0)), "ok", true));
  {
    const std::string updated = TakeAndFree(
        wb_element_update(elementId.c_str(), "{\"text\":\"解锁后\"}"));
    REQUIRE(JsonBool(updated, "ok", true));
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonContains(listed, "\"text\":\"解锁后\""));
  }
}

TEST_CASE("page element: hide state reflects in page.list",
          "[integration][page][element]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  REQUIRE_FALSE(CreateElement(scene.pageId, RectElement(0, 0, 10, 10, "hidden-test"))
                    .empty());

  // 隐藏页面：页面摘要 hidden=true，元素数据保留。
  CHECK(JsonBool(TakeAndFree(wb_page_hide(scene.pageId.c_str(), 1)), "ok", true));
  {
    const std::string pages =
        TakeAndFree(wb_page_list(scene.boardId.c_str()));
    REQUIRE(JsonBool(pages, "hidden", true));
    const std::string listed =
        TakeAndFree(wb_element_list(scene.pageId.c_str()));
    REQUIRE(JsonNumber(listed, "count") == 1.0);
    REQUIRE(JsonContains(listed, "hidden-test"));
  }

  // 恢复显示。
  CHECK(JsonBool(TakeAndFree(wb_page_hide(scene.pageId.c_str(), 0)), "ok", true));
  {
    const std::string pages =
        TakeAndFree(wb_page_list(scene.boardId.c_str()));
    REQUIRE(JsonBool(pages, "hidden", false));
  }
}

TEST_CASE("page element: last page delete guard and normal delete",
          "[integration][page][element]") {
  const Scene scene = MakeScene();
  REQUIRE(scene.ok);

  // 仅一页时删除被拒绝（Conflict）。
  const std::string denied = TakeAndFree(wb_page_delete(scene.pageId.c_str()));
  REQUIRE(JsonBool(denied, "ok", false));
  REQUIRE(JsonContains(denied, "last page"));

  // 新建第二页后可删除其中一页。
  const std::string page2Response =
      TakeAndFree(wb_page_create(scene.boardId.c_str(), "{}"));
  const std::string page2 = JsonString(page2Response, "pageId");
  REQUIRE_FALSE(page2.empty());
  const std::string deleted = TakeAndFree(wb_page_delete(page2.c_str()));
  REQUIRE(JsonBool(deleted, "ok", true));
  REQUIRE(JsonContains(deleted, "\"deleted\""));
  REQUIRE(JsonString(deleted, "boardId") == scene.boardId);
  {
    const std::string pages =
        TakeAndFree(wb_page_list(scene.boardId.c_str()));
    REQUIRE(JsonNumber(pages, "count") == 1.0);
  }
}
