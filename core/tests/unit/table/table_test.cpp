// tests/unit/table/table_test.cpp — domain "table" (1.5).

#include <cmath>
#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

namespace {

struct Scene {
  std::string board;
  std::string pageId;
};

Scene NewScene() {
  Scene scene;
  SceneNewBoard(&scene.board);
  scene.pageId = SceneFirstPageId(scene.board);
  return scene;
}

std::string CreateTable(const Scene& scene, int rows = 6) {
  const std::string response = wb::invokeDomain(
      "table", "create",
      "{\"pageId\":\"" + scene.pageId +
          "\",\"element\":{\"position\":{\"x\":0,\"y\":0},"
          "\"size\":{\"width\":400,\"height\":300},"
          "\"data\":{\"rows\":" + std::to_string(rows) + ",\"cols\":3}}}");
  return JsonBool(response, "ok", true) ? JsonString(response, "elementId")
                                        : std::string();
}

void SetCell(const std::string& tableId, const std::string& address,
             const std::string& valueJson) {
  const std::string response = wb::invokeDomain(
      "table", "setCell",
      "{\"tableId\":\"" + tableId + "\",\"address\":\"" + address +
          "\",\"value\":" + valueJson + "}");
  REQUIRE(JsonBool(response, "ok", true));
}

void SetFormula(const std::string& tableId, const std::string& address,
                const std::string& formula) {
  const std::string response = wb::invokeDomain(
      "table", "setFormula",
      "{\"tableId\":\"" + tableId + "\",\"address\":\"" + address +
          "\",\"formula\":\"" + formula + "\"}");
  REQUIRE(JsonBool(response, "ok", true));
}

double GetNumber(const std::string& tableId, const std::string& address) {
  const std::string response = wb::invokeDomain(
      "table", "getCell",
      "{\"tableId\":\"" + tableId + "\",\"address\":\"" + address + "\"}");
  REQUIRE(JsonBool(response, "ok", true));
  bool ok = false;
  const double value = JsonNumber(response, "value", &ok);
  REQUIRE(ok);
  return value;
}

}  // namespace

TEST_CASE("table setCell stores values and getCell reads them", "[table]") {
  const Scene scene = NewScene();
  const std::string table = CreateTable(scene);
  REQUIRE(!table.empty());

  SetCell(table, "A1", "10");
  SetCell(table, "a1", "12");  // addresses are normalized to upper case
  REQUIRE(GetNumber(table, "A1") == 12.0);

  const std::string text = wb::invokeDomain(
      "table", "setCell",
      "{\"tableId\":\"" + table + "\",\"address\":\"B1\",\"value\":\"王小明\"}");
  REQUIRE(JsonBool(text, "ok", true));
  REQUIRE(JsonContains(text, "\"value\":\"王小明\""));

  const std::string badAddress = wb::invokeDomain(
      "table", "setCell",
      "{\"tableId\":\"" + table + "\",\"address\":\"1A\",\"value\":1}");
  REQUIRE(JsonBool(badAddress, "ok", false));
  REQUIRE(JsonString(badAddress, "code") == "InvalidArgument");

  const std::string noValue = wb::invokeDomain(
      "table", "setCell",
      "{\"tableId\":\"" + table + "\",\"address\":\"A2\"}");
  REQUIRE(JsonBool(noValue, "ok", false));
  REQUIRE(JsonString(noValue, "code") == "InvalidArgument");

  // Unknown cells come back empty rather than as an error.
  const std::string empty = wb::invokeDomain(
      "table", "getCell",
      "{\"tableId\":\"" + table + "\",\"address\":\"C9\"}");
  REQUIRE(JsonBool(empty, "ok", true));
  REQUIRE(JsonContains(empty, "\"cell\":{}"));
}

TEST_CASE("table formulas evaluate and re-evaluate dependents", "[table]") {
  const Scene scene = NewScene();
  const std::string table = CreateTable(scene);
  SetCell(table, "A1", "1");
  SetCell(table, "A2", "2");
  SetCell(table, "A3", "3");

  SetFormula(table, "A4", "=SUM(A1:A3)");
  REQUIRE(GetNumber(table, "A4") == 6.0);
  SetFormula(table, "B1", "=AVG(A1:A3)");
  REQUIRE(GetNumber(table, "B1") == 2.0);
  SetFormula(table, "B2", "=A4*2");
  REQUIRE(GetNumber(table, "B2") == 12.0);
  SetFormula(table, "B3", "=IF(A1<0,-1,1)");
  REQUIRE(GetNumber(table, "B3") == 1.0);
  SetFormula(table, "C1", "=COUNTA(A1:A3)+1");
  REQUIRE(GetNumber(table, "C1") == 4.0);

  // Updating a leaf recomputes the whole chain (A4 -> B2).
  SetCell(table, "A1", "10");
  REQUIRE(GetNumber(table, "A4") == 15.0);
  REQUIRE(GetNumber(table, "B2") == 30.0);
  REQUIRE(GetNumber(table, "B1") == 5.0);
}

TEST_CASE("table formulas surface cycle and division errors", "[table]") {
  const Scene scene = NewScene();
  const std::string table = CreateTable(scene);

  SetFormula(table, "C1", "=C2");  // empty reference resolves to 0
  REQUIRE(GetNumber(table, "C1") == 0.0);

  const std::string cycle = wb::invokeDomain(
      "table", "setFormula",
      "{\"tableId\":\"" + table + "\",\"address\":\"C2\",\"formula\":\"=C1\"}");
  REQUIRE(JsonBool(cycle, "ok", true));
  REQUIRE(JsonContains(cycle, "#CYCLE!"));

  const std::string divide = wb::invokeDomain(
      "table", "setFormula",
      "{\"tableId\":\"" + table + "\",\"address\":\"D1\",\"formula\":\"=1/0\"}");
  REQUIRE(JsonBool(divide, "ok", true));
  REQUIRE(JsonContains(divide, "#DIV/0!"));
}

TEST_CASE("table sort reorders rows by a column", "[table]") {
  const Scene scene = NewScene();
  const std::string table = CreateTable(scene, 3);
  SetCell(table, "A1", "3");
  SetCell(table, "A2", "1");
  SetCell(table, "A3", "2");
  SetCell(table, "B1", "\"三\"");
  SetCell(table, "B2", "\"一\"");
  SetCell(table, "B3", "\"二\"");

  const std::string ascending = wb::invokeDomain(
      "table", "sort",
      "{\"tableId\":\"" + table +
          "\",\"column\":\"A\",\"ascending\":true,\"hasHeader\":false}");
  REQUIRE(JsonBool(ascending, "ok", true));
  REQUIRE(JsonContains(ascending, "\"order\":[2,3,1]"));
  REQUIRE(GetNumber(table, "A1") == 1.0);
  REQUIRE(GetNumber(table, "A3") == 3.0);
  // Sibling columns follow the row order.
  const std::string b1 = wb::invokeDomain(
      "table", "getCell",
      "{\"tableId\":\"" + table + "\",\"address\":\"B1\"}");
  REQUIRE(JsonContains(b1, "一"));

  const std::string descending = wb::invokeDomain(
      "table", "sort",
      "{\"tableId\":\"" + table +
          "\",\"column\":\"A\",\"ascending\":false,\"hasHeader\":false}");
  REQUIRE(JsonContains(descending, "\"order\":[3,2,1]"));

  const std::string badColumn = wb::invokeDomain(
      "table", "sort", "{\"tableId\":\"" + table + "\",\"column\":\"1\"}");
  REQUIRE(JsonBool(badColumn, "ok", false));
  REQUIRE(JsonString(badColumn, "code") == "InvalidArgument");
}

TEST_CASE("table filter matches numeric and text predicates", "[table]") {
  const Scene scene = NewScene();
  const std::string table = CreateTable(scene);
  SetCell(table, "A1", "5");
  SetCell(table, "A2", "15");
  SetCell(table, "A3", "25");
  SetCell(table, "B1", "\"apple\"");
  SetCell(table, "B2", "\"banana\"");

  const std::string greater = wb::invokeDomain(
      "table", "filter",
      "{\"tableId\":\"" + table +
          "\",\"column\":\"A\",\"op\":\">\",\"value\":10,\"hasHeader\":false}");
  REQUIRE(JsonBool(greater, "ok", true));
  REQUIRE(JsonContains(greater, "\"matches\":[2,3]"));
  REQUIRE(JsonNumber(greater, "count") == 2.0);

  const std::string contains = wb::invokeDomain(
      "table", "filter",
      "{\"tableId\":\"" + table +
          "\",\"column\":\"B\",\"op\":\"contains\",\"value\":\"an\","
          "\"hasHeader\":false}");
  REQUIRE(JsonContains(contains, "\"matches\":[2]"));

  const std::string noValue = wb::invokeDomain(
      "table", "filter",
      "{\"tableId\":\"" + table + "\",\"column\":\"A\",\"op\":\">\"}");
  REQUIRE(JsonBool(noValue, "ok", false));
  REQUIRE(JsonString(noValue, "code") == "InvalidArgument");
}

TEST_CASE("table setStyle merges element and cell-range styles", "[table]") {
  const Scene scene = NewScene();
  const std::string table = CreateTable(scene);

  const std::string global = wb::invokeDomain(
      "table", "setStyle",
      "{\"tableId\":\"" + table +
          "\",\"style\":{\"headerColor\":\"#123456\"}}");
  REQUIRE(JsonBool(global, "ok", true));
  REQUIRE(JsonContains(global, "\"headerColor\":\"#123456\""));

  const std::string range = wb::invokeDomain(
      "table", "setStyle",
      "{\"tableId\":\"" + table +
          "\",\"cellRange\":\"A1:B2\",\"style\":{\"bold\":true}}");
  REQUIRE(JsonBool(range, "ok", true));
  REQUIRE(JsonContains(range, "\"bold\":true"));

  const std::string noStyle = wb::invokeDomain(
      "table", "setStyle", "{\"tableId\":\"" + table + "\"}");
  REQUIRE(JsonBool(noStyle, "ok", false));
  REQUIRE(JsonString(noStyle, "code") == "InvalidArgument");
}

TEST_CASE("table guards element type, lock and list", "[table]") {
  const Scene scene = NewScene();
  const std::string table = CreateTable(scene);
  const std::string sticky = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":10,\"height\":10}}");

  const std::string wrong = wb::invokeDomain(
      "table", "setCell",
      "{\"tableId\":\"" + sticky + "\",\"address\":\"A1\",\"value\":1}");
  REQUIRE(JsonBool(wrong, "ok", false));
  REQUIRE(JsonString(wrong, "code") == "InvalidArgument");

  const std::string missing = wb::invokeDomain(
      "table", "setCell",
      "{\"tableId\":\"element-nope\",\"address\":\"A1\",\"value\":1}");
  REQUIRE(JsonString(missing, "code") == "NotFound");

  const std::string list = wb::invokeDomain(
      "table", "list", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonNumber(list, "count") == 1.0);
  REQUIRE(JsonContains(list, "\"rows\":6"));
  REQUIRE(JsonContains(list, "\"cols\":3"));

  wb::invokeDomain("page", "lock",
                   "{\"pageId\":\"" + scene.pageId + "\",\"locked\":true}");
  const std::string locked = wb::invokeDomain(
      "table", "setCell",
      "{\"tableId\":\"" + table + "\",\"address\":\"A1\",\"value\":1}");
  REQUIRE(JsonBool(locked, "ok", false));
  REQUIRE(JsonString(locked, "code") == "Conflict");
}
