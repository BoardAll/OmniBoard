// tests/unit/render3d/render3d_test.cpp — domain "render3d" (1.6).

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

std::string Create3dRaw(const Scene& scene, const std::string& dataJson = "") {
  std::string element =
      "{\"position\":{\"x\":0,\"y\":0},\"size\":{\"width\":400,\"height\":300}";
  if (!dataJson.empty()) element += ",\"data\":" + dataJson;
  element += "}";
  return wb::invokeDomain("render3d", "create",
                          "{\"pageId\":\"" + scene.pageId +
                              "\",\"element\":" + element + "}");
}

std::string Create3d(const Scene& scene, const std::string& dataJson = "") {
  const std::string response = Create3dRaw(scene, dataJson);
  return JsonBool(response, "ok", true) ? JsonString(response, "elementId")
                                        : std::string();
}

std::string Render(const std::string& id, int width, int height) {
  return wb::invokeDomain(
      "render3d", "render",
      "{\"elementId\":\"" + id + "\",\"width\":" + std::to_string(width) +
          ",\"height\":" + std::to_string(height) + "}");
}

std::string Pick(const std::string& id, double x, double y) {
  return wb::invokeDomain("render3d", "pickSurface",
                          "{\"elementId\":\"" + id + "\",\"x\":" +
                              std::to_string(x) + ",\"y\":" +
                              std::to_string(y) + "}");
}

}  // namespace

TEST_CASE("render3d create builds a box mesh and render reports the job",
          "[render3d]") {
  const Scene scene = NewScene();
  const std::string create = Create3dRaw(scene);
  REQUIRE(JsonBool(create, "ok", true));
  const std::string cube = JsonString(create, "elementId");
  REQUIRE(JsonString(create, "geometryType") == "box");
  REQUIRE(JsonNumber(create, "vertexCount") == 8.0);
  REQUIRE(JsonNumber(create, "faceCount") == 6.0);
  REQUIRE(JsonContains(create, "\"faces\":["));

  const std::string render = Render(cube, 640, 480);
  REQUIRE(JsonBool(render, "ok", true));
  REQUIRE(JsonString(render, "jobId") == "job-1");
  REQUIRE(JsonNumber(render, "frame") == 1.0);
  REQUIRE(JsonNumber(render, "vertexCount") == 8.0);
  REQUIRE(JsonNumber(render, "triangleCount") == 12.0);
  REQUIRE(JsonNumber(render, "lightCount") == 2.0);
  REQUIRE(JsonBool(render, "offscreen", true));

  const std::string again = Render(cube, 800, 600);
  REQUIRE(JsonString(again, "jobId") == "job-2");
  REQUIRE(JsonNumber(again, "frame") == 2.0);
  REQUIRE(JsonNumber(again, "width") == 800.0);

  const std::string badSize = Render(cube, 0, 480);
  REQUIRE(JsonBool(badSize, "ok", false));
  REQUIRE(JsonString(badSize, "code") == "InvalidArgument");
}

TEST_CASE("render3d pickSurface hits the front face at the viewport centre",
          "[render3d]") {
  const Scene scene = NewScene();
  const std::string cube = Create3d(scene);
  REQUIRE(!cube.empty());

  const std::string hit = Pick(cube, 320.0, 240.0);
  REQUIRE(JsonBool(hit, "ok", true));
  REQUIRE(JsonBool(hit, "hit", true));
  REQUIRE(JsonNumber(hit, "faceId") == 1.0);
  // Camera at z=300, front face at z=50 -> distance 250.
  REQUIRE(std::fabs(JsonNumber(hit, "distance") - 250.0) < 1e-6);
  const std::size_t point = hit.find("\"point\"");
  REQUIRE(point != std::string::npos);
  REQUIRE(std::fabs(JsonNumberAt(hit, "z", point) - 50.0) < 1e-6);

  // A corner ray leaves the box entirely.
  const std::string miss = Pick(cube, 0.0, 0.0);
  REQUIRE(JsonBool(miss, "ok", true));
  REQUIRE(JsonBool(miss, "hit", false));
}

TEST_CASE("render3d transform scales the picked geometry", "[render3d]") {
  const Scene scene = NewScene();
  const std::string cube = Create3d(scene);
  const std::string transform = wb::invokeDomain(
      "render3d", "transform",
      "{\"elementId\":\"" + cube +
          "\",\"transform\":{\"scale\":{\"x\":2,\"y\":2,\"z\":2}}}");
  REQUIRE(JsonBool(transform, "ok", true));
  const std::size_t scale = transform.find("\"scale\"");
  REQUIRE(scale != std::string::npos);
  REQUIRE(JsonNumberAt(transform, "x", scale) == 2.0);

  // Scaled box: front face at z=100 -> distance 200.
  const std::string hit = Pick(cube, 320.0, 240.0);
  REQUIRE(JsonBool(hit, "hit", true));
  REQUIRE(std::fabs(JsonNumber(hit, "distance") - 200.0) < 1e-6);
}

TEST_CASE("render3d setFaceColor, setMaterial and setLight validate input",
          "[render3d]") {
  const Scene scene = NewScene();
  const std::string cube = Create3d(scene);

  const std::string painted = wb::invokeDomain(
      "render3d", "setFaceColor",
      "{\"elementId\":\"" + cube +
          "\",\"faceId\":1,\"color\":\"#FF0000\"}");
  REQUIRE(JsonBool(painted, "ok", true));
  REQUIRE(JsonContains(painted, "\"color\":\"#FF0000\""));
  REQUIRE(JsonNumber(painted, "faceId") == 1.0);

  const std::string badFace = wb::invokeDomain(
      "render3d", "setFaceColor",
      "{\"elementId\":\"" + cube + "\",\"faceId\":99,\"color\":\"#FF0000\"}");
  REQUIRE(JsonBool(badFace, "ok", false));
  REQUIRE(JsonString(badFace, "code") == "NotFound");

  const std::string badColor = wb::invokeDomain(
      "render3d", "setFaceColor",
      "{\"elementId\":\"" + cube + "\",\"faceId\":1,\"color\":\"red\"}");
  REQUIRE(JsonBool(badColor, "ok", false));
  REQUIRE(JsonString(badColor, "code") == "InvalidArgument");

  const std::string material = wb::invokeDomain(
      "render3d", "setMaterial",
      "{\"elementId\":\"" + cube +
          "\",\"material\":{\"metallic\":0.5,\"baseColor\":\"#112233\"}}");
  REQUIRE(JsonBool(material, "ok", true));
  REQUIRE(JsonContains(material, "\"metallic\":0.5"));
  REQUIRE(JsonContains(material, "\"baseColor\":\"#112233\""));

  const std::string badMaterial = wb::invokeDomain(
      "render3d", "setMaterial",
      "{\"elementId\":\"" + cube + "\",\"material\":{\"metallic\":1.5}}");
  REQUIRE(JsonBool(badMaterial, "ok", false));
  REQUIRE(JsonString(badMaterial, "code") == "InvalidArgument");

  const std::string light = wb::invokeDomain(
      "render3d", "setLight",
      "{\"elementId\":\"" + cube +
          "\",\"light\":{\"type\":\"point\",\"color\":\"#00FF00\","
          "\"intensity\":2,\"position\":{\"x\":10,\"y\":20,\"z\":30}}}");
  REQUIRE(JsonBool(light, "ok", true));
  REQUIRE(JsonNumber(light, "lightCount") == 3.0);

  const std::string badLight = wb::invokeDomain(
      "render3d", "setLight",
      "{\"elementId\":\"" + cube + "\",\"light\":{\"type\":\"spot\"}}");
  REQUIRE(JsonBool(badLight, "ok", false));
  REQUIRE(JsonString(badLight, "code") == "InvalidArgument");

  const std::string replace = wb::invokeDomain(
      "render3d", "setLight",
      "{\"elementId\":\"" + cube +
          "\",\"light\":{\"type\":\"ambient\"},\"index\":0}");
  REQUIRE(JsonBool(replace, "ok", true));
  REQUIRE(JsonNumber(replace, "lightCount") == 3.0);

  const std::string badIndex = wb::invokeDomain(
      "render3d", "setLight",
      "{\"elementId\":\"" + cube +
          "\",\"light\":{\"type\":\"ambient\"},\"index\":9}");
  REQUIRE(JsonBool(badIndex, "ok", false));
  REQUIRE(JsonString(badIndex, "code") == "NotFound");
}

TEST_CASE("render3d export produces OBJ and glTF content", "[render3d]") {
  const Scene scene = NewScene();
  const std::string cube = Create3d(scene);

  const std::string obj = wb::invokeDomain(
      "render3d", "export",
      "{\"elementId\":\"" + cube + "\",\"format\":\"obj\"}");
  REQUIRE(JsonBool(obj, "ok", true));
  REQUIRE(JsonString(obj, "format") == "obj");
  REQUIRE(JsonContains(obj, "vertices: 8 faces: 6"));
  REQUIRE(JsonContains(obj, "v -50 -50 50"));
  REQUIRE(JsonContains(obj, "f 1 2 3"));

  const std::string gltf = wb::invokeDomain(
      "render3d", "export",
      "{\"elementId\":\"" + cube + "\",\"format\":\"gltf\"}");
  REQUIRE(JsonBool(gltf, "ok", true));
  REQUIRE(JsonString(gltf, "format") == "gltf");
  REQUIRE(JsonContains(gltf, "whiteboard-core"));
  REQUIRE(JsonContains(gltf, "POSITION"));

  const std::string bad = wb::invokeDomain(
      "render3d", "export",
      "{\"elementId\":\"" + cube + "\",\"format\":\"stl\"}");
  REQUIRE(JsonBool(bad, "ok", false));
  REQUIRE(JsonString(bad, "code") == "InvalidArgument");
}

TEST_CASE("render3d guards type, geometry, lock and list", "[render3d]") {
  const Scene scene = NewScene();
  const std::string cube = Create3d(scene);
  const std::string cylinder =
      Create3d(scene, "{\"geometry\":\"cylinder\"}");
  REQUIRE(!cube.empty());
  REQUIRE(!cylinder.empty());

  const std::string cylinderRaw =
      Create3dRaw(scene, "{\"geometry\":{\"type\":\"cylinder\",\"segments\":16}}");
  REQUIRE(JsonNumber(cylinderRaw, "vertexCount") == 32.0);
  REQUIRE(JsonNumber(cylinderRaw, "faceCount") == 18.0);

  const std::string badGeometry =
      Create3dRaw(scene, "{\"geometry\":\"banana\"}");
  REQUIRE(JsonBool(badGeometry, "ok", false));
  REQUIRE(JsonString(badGeometry, "code") == "InvalidArgument");

  const std::string sticky = SceneCreateElement(
      scene.pageId,
      "{\"type\":\"sticky\",\"position\":{\"x\":0,\"y\":0},"
      "\"size\":{\"width\":10,\"height\":10}}");
  const std::string wrong = Render(sticky, 100, 100);
  REQUIRE(JsonBool(wrong, "ok", false));
  REQUIRE(JsonString(wrong, "code") == "InvalidArgument");

  const std::string missing = Render("element-nope", 100, 100);
  REQUIRE(JsonString(missing, "code") == "NotFound");

  const std::string list = wb::invokeDomain(
      "render3d", "list", "{\"pageId\":\"" + scene.pageId + "\"}");
  REQUIRE(JsonNumber(list, "count") == 3.0);
  REQUIRE(JsonContains(list, "\"geometryType\":\"box\""));
  REQUIRE(JsonContains(list, "\"faceCount\":18"));

  wb::invokeDomain("page", "lock",
                   "{\"pageId\":\"" + scene.pageId + "\",\"locked\":true}");
  const std::string locked = wb::invokeDomain(
      "render3d", "setFaceColor",
      "{\"elementId\":\"" + cube +
          "\",\"faceId\":1,\"color\":\"#FF0000\"}");
  REQUIRE(JsonBool(locked, "ok", false));
  REQUIRE(JsonString(locked, "code") == "Conflict");
}
