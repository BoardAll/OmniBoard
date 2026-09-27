// tests/unit/annotation/annotation_test.cpp — domain "annotation" (1.6).
//
// catch_discover_tests runs every TEST_CASE in its own process, so the
// process-wide transparent-mode state starts fresh here each time.

#include <string>

#include <catch2/catch_test_macros.hpp>

#include "../support/scene_probe.h"

namespace {

std::string Enter(const std::string& configBody = "") {
  if (configBody.empty()) {
    return wb::invokeDomain("annotation", "enterTransparent", "{}");
  }
  return wb::invokeDomain("annotation", "enterTransparent",
                          "{\"config\":" + configBody + "}");
}

std::string Exit(const std::string& action) {
  return wb::invokeDomain("annotation", "exitTransparent",
                          "{\"action\":{\"action\":\"" + action + "\"}}");
}

std::string AddStroke(const std::string& body) {
  return wb::invokeDomain("annotation", "addStroke",
                          "{\"stroke\":" + body + "}");
}

const char* kPen =
    "{\"tool\":\"pen\",\"color\":\"#FF0000\",\"width\":2,"
    "\"points\":[{\"x\":1,\"y\":2},{\"x\":3,\"y\":4}]}";

}  // namespace

TEST_CASE("annotation transparent mode toggles between annotate and penetrate",
          "[annotation]") {
  const std::string initial =
      wb::invokeDomain("annotation", "state", "{}");
  REQUIRE(JsonBool(initial, "ok", true));
  REQUIRE(JsonBool(initial, "active", false));
  REQUIRE(JsonString(initial, "mode") == "none");

  const std::string entered = Enter("{\"opacity\":0.25}");
  REQUIRE(JsonBool(entered, "ok", true));
  REQUIRE(JsonBool(entered, "active", true));
  REQUIRE(JsonString(entered, "mode") == "annotate");  // 默认进入批注态
  REQUIRE(JsonContains(entered, "\"opacity\":0.25"));
  REQUIRE(JsonNumber(entered, "restoredStrokes") == 0.0);

  const std::string again = Enter();
  REQUIRE(JsonBool(again, "ok", false));
  REQUIRE(JsonString(again, "code") == "Conflict");

  const std::string penetrate = wb::invokeDomain(
      "annotation", "setPenetrate", "{\"penetrate\":true}");
  REQUIRE(JsonBool(penetrate, "ok", true));
  REQUIRE(JsonString(penetrate, "mode") == "penetrate");
  REQUIRE(JsonBool(penetrate, "penetrate", true));

  // Penetrate mode forwards input to the system: no strokes are captured.
  const std::string blocked = AddStroke(kPen);
  REQUIRE(JsonBool(blocked, "ok", false));
  REQUIRE(JsonString(blocked, "code") == "Conflict");

  const std::string back = wb::invokeDomain("annotation", "setPenetrate",
                                            "{\"penetrate\":0}");
  REQUIRE(JsonBool(back, "ok", true));
  REQUIRE(JsonString(back, "mode") == "annotate");

  const std::string pen = AddStroke(kPen);
  REQUIRE(JsonBool(pen, "ok", true));
  REQUIRE(JsonBool(pen, "saved", true));
  REQUIRE(JsonString(pen, "tool") == "pen");
  REQUIRE(JsonNumber(pen, "strokeCount") == 1.0);

  // Laser strokes are transient and never stored (§6.1).
  const std::string laser = AddStroke(
      "{\"tool\":\"laser\",\"color\":\"#00FF00\",\"points\":[{\"x\":0,\"y\":0}]}");
  REQUIRE(JsonBool(laser, "ok", true));
  REQUIRE(JsonBool(laser, "saved", false));
  REQUIRE(JsonNumber(laser, "strokeCount") == 1.0);

  const std::string undone = wb::invokeDomain("annotation", "undo", "{}");
  REQUIRE(JsonBool(undone, "undone", true));
  REQUIRE(JsonNumber(undone, "strokeCount") == 0.0);

  const std::string nothing = wb::invokeDomain("annotation", "undo", "{}");
  REQUIRE(JsonBool(nothing, "ok", false));
  REQUIRE(JsonString(nothing, "code") == "InvalidArgument");

  const std::string redone = wb::invokeDomain("annotation", "redo", "{}");
  REQUIRE(JsonBool(redone, "redone", true));
  REQUIRE(JsonNumber(redone, "strokeCount") == 1.0);

  const std::string cleared = wb::invokeDomain("annotation", "clear", "{}");
  REQUIRE(JsonNumber(cleared, "clearedStrokes") == 1.0);
  REQUIRE(JsonNumber(cleared, "strokeCount") == 0.0);
}

TEST_CASE("annotation exit actions save, discard or keep strokes",
          "[annotation]") {
  REQUIRE(JsonBool(Enter(), "ok", true));
  REQUIRE(JsonBool(AddStroke(kPen), "saved", true));
  REQUIRE(JsonNumber(AddStroke(
              "{\"tool\":\"laser\",\"color\":\"#00FF00\","
              "\"points\":[{\"x\":0,\"y\":0}]}"),
                    "strokeCount") == 1.0);

  const std::string saved = Exit("save");
  REQUIRE(JsonBool(saved, "ok", true));
  REQUIRE(JsonString(saved, "action") == "save");
  REQUIRE(JsonNumber(saved, "savedStrokes") == 1.0);
  REQUIRE(JsonBool(saved, "active", false));
  REQUIRE(JsonNumber(saved, "strokeCount") == 0.0);

  // A "keep" exit retains the layer for the next enter.
  REQUIRE(JsonNumber(Enter(), "restoredStrokes") == 0.0);
  REQUIRE(JsonBool(AddStroke(kPen), "saved", true));
  const std::string kept = Exit("keep");
  REQUIRE(JsonString(kept, "action") == "keep");
  REQUIRE(JsonNumber(kept, "keptStrokes") == 1.0);
  REQUIRE(JsonNumber(kept, "strokeCount") == 1.0);
  REQUIRE(JsonNumber(Enter(), "restoredStrokes") == 1.0);

  // A "discard" exit drops everything.
  const std::string discarded = Exit("discard");
  REQUIRE(JsonString(discarded, "action") == "discard");
  REQUIRE(JsonNumber(discarded, "discardedStrokes") == 1.0);
  REQUIRE(JsonNumber(discarded, "strokeCount") == 0.0);
  REQUIRE(JsonNumber(Enter(), "restoredStrokes") == 0.0);

  // saveToBoard merges the layer without leaving the mode.
  REQUIRE(JsonBool(AddStroke(kPen), "saved", true));
  const std::string toBoard =
      wb::invokeDomain("annotation", "saveToBoard", "{}");
  REQUIRE(JsonBool(toBoard, "ok", true));
  REQUIRE(JsonNumber(toBoard, "savedStrokes") == 1.0);
  REQUIRE(JsonString(toBoard, "savedAs") == "frame");
  const std::string state = wb::invokeDomain("annotation", "state", "{}");
  REQUIRE(JsonBool(state, "active", true));
  REQUIRE(JsonNumber(state, "strokeCount") == 0.0);
}

TEST_CASE("annotation rejects invalid input and wrong states", "[annotation]") {
  const std::string inactiveExit = Exit("save");
  REQUIRE(JsonBool(inactiveExit, "ok", false));
  REQUIRE(JsonString(inactiveExit, "code") == "Conflict");

  const std::string inactivePen = wb::invokeDomain(
      "annotation", "setPenetrate", "{\"penetrate\":true}");
  REQUIRE(JsonBool(inactivePen, "ok", false));
  REQUIRE(JsonString(inactivePen, "code") == "Conflict");

  const std::string inactiveStroke = AddStroke(kPen);
  REQUIRE(JsonBool(inactiveStroke, "ok", false));
  REQUIRE(JsonString(inactiveStroke, "code") == "Conflict");

  const std::string badOpacity = Enter("{\"opacity\":2}");
  REQUIRE(JsonBool(badOpacity, "ok", false));
  REQUIRE(JsonString(badOpacity, "code") == "InvalidArgument");

  const std::string badTarget = Enter("{\"saveTarget\":\"paper\"}");
  REQUIRE(JsonBool(badTarget, "ok", false));
  REQUIRE(JsonString(badTarget, "code") == "InvalidArgument");

  // config.penetrate starts the mode directly in 穿透态.
  const std::string penetrated = Enter("{\"penetrate\":true}");
  REQUIRE(JsonBool(penetrated, "ok", true));
  REQUIRE(JsonString(penetrated, "mode") == "penetrate");
  REQUIRE(JsonBool(
      wb::invokeDomain("annotation", "setPenetrate", "{\"penetrate\":false}"),
      "ok", true));

  const std::string noStroke =
      wb::invokeDomain("annotation", "addStroke", "{}");
  REQUIRE(JsonBool(noStroke, "ok", false));
  REQUIRE(JsonString(noStroke, "code") == "InvalidArgument");

  const std::string badTool = AddStroke(
      "{\"tool\":\"brush\",\"color\":\"#FF0000\","
      "\"points\":[{\"x\":0,\"y\":0}]}");
  REQUIRE(JsonBool(badTool, "ok", false));
  REQUIRE(JsonString(badTool, "code") == "InvalidArgument");

  const std::string badColor = AddStroke(
      "{\"tool\":\"pen\",\"color\":\"red\",\"points\":[{\"x\":0,\"y\":0}]}");
  REQUIRE(JsonBool(badColor, "ok", false));
  REQUIRE(JsonString(badColor, "code") == "InvalidArgument");

  const std::string noPoints =
      AddStroke("{\"tool\":\"pen\",\"color\":\"#FF0000\"}");
  REQUIRE(JsonBool(noPoints, "ok", false));
  REQUIRE(JsonString(noPoints, "code") == "InvalidArgument");

  const std::string badPoint = AddStroke(
      "{\"tool\":\"pen\",\"color\":\"#FF0000\",\"points\":[{\"x\":\"a\"}]}");
  REQUIRE(JsonBool(badPoint, "ok", false));
  REQUIRE(JsonString(badPoint, "code") == "InvalidArgument");

  const std::string noFlag =
      wb::invokeDomain("annotation", "setPenetrate", "{}");
  REQUIRE(JsonBool(noFlag, "ok", false));
  REQUIRE(JsonString(noFlag, "code") == "InvalidArgument");

  const std::string badAction = Exit("burn");
  REQUIRE(JsonBool(badAction, "ok", false));
  REQUIRE(JsonString(badAction, "code") == "InvalidArgument");

  const std::string emptyEraser = AddStroke(
      "{\"tool\":\"eraser\",\"color\":\"#FF0000\","
      "\"points\":[{\"x\":0,\"y\":0}]}");
  REQUIRE(JsonBool(emptyEraser, "ok", false));
  REQUIRE(JsonString(emptyEraser, "code") == "InvalidArgument");

  const std::string first = AddStroke(kPen);
  REQUIRE(JsonBool(first, "ok", true));
  REQUIRE(JsonNumber(AddStroke(kPen), "strokeCount") == 2.0);
  const std::string erased = AddStroke(
      "{\"tool\":\"eraser\",\"color\":\"#FF0000\","
      "\"points\":[{\"x\":0,\"y\":0}]}");
  REQUIRE(JsonBool(erased, "ok", true));
  REQUIRE(JsonBool(erased, "erased", true));
  REQUIRE(JsonNumber(erased, "strokeCount") == 1.0);
}
