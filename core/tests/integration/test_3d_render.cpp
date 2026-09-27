// tests/integration/test_3d_render.cpp — 集成链路：3D 元素 × 渲染数据生成
// （《测试方案设计》§7.1 清单第 5 项）。
//
// 覆盖链路：
//   1. 3D create（box 网格数据 8 顶点 6 面）→ render 帧递增（job-N/frame）→
//      render.getDisplayList 进入 Render3D 层、dirtyRect 与元素几何对齐。
//   2. 面颜色 / 材质 / 光照 / 变换设置 → 数据模型联动。
//   3. export(obj/gltf) → 变换后的世界坐标顶点、结构数据链路。
//   4. pickSurface 射线拾取 → 相机(0,0,300) 中心像素命中前面（faceId 1、
//      距离 250、交点 z=50），未知元素 NotFound。
//
// 注：本测试只走数据模型与导出通道，不依赖 GPU/后端渲染（WB_BUILD_3D
// 关闭时整体不编译 render3d，相关用例不会注册）。
// nlohmann 按键字典序 dump：obj/gltf 的 content 为内嵌转义字符串，
// 探针按原始转义形态匹配；整数与浮点在 dump 中保留原字面形态。

#include <catch2/catch_test_macros.hpp>

#include <string>
#include <vector>

#include "support/test_probe.h"

namespace {

/// 建好 3D 元素（显式几何，便于渲染 dirtyRect 断言）。
struct Scene3d {
  Scene scene;
  std::string elementId;
  std::string created;  // wb_3d_create 原始响应
};

Scene3d Build3d() {
  Scene3d s3;
  s3.scene = MakeScene();
  s3.created = TakeAndFree(wb_3d_create(
      s3.scene.pageId.c_str(),
      "{\"position\":{\"x\":10,\"y\":20},\"size\":{\"width\":200,"
      "\"height\":150}}"));
  s3.elementId = JsonString(s3.created, "elementId");
  return s3;
}

}  // namespace

TEST_CASE("3d render: geometry build and display list linkage",
          "[integration][render3d][render]") {
  const Scene3d s3 = Build3d();
  REQUIRE(s3.scene.ok);
  REQUIRE_FALSE(s3.elementId.empty());

  // 1) create：默认 box 网格 = 8 顶点 / 6 面，每面都有索引环。
  const std::string& created = s3.created;
  REQUIRE(JsonBool(created, "ok", true));
  REQUIRE(JsonContains(created, "\"type\":\"render3d\""));
  REQUIRE(JsonContains(created, "\"geometryType\":\"box\""));
  REQUIRE(JsonNumber(created, "vertexCount") == 8.0);
  REQUIRE(JsonNumber(created, "faceCount") == 6.0);
  REQUIRE(JsonArrayLength(created, "faces") == 6);
  REQUIRE(CountOccurrences(created, "\"indices\":[") == 6);

  // 2) render：job/frame 递增；box 12 三角形；默认双光源、离屏模式。
  const std::string frame1 =
      TakeAndFree(wb_3d_render(s3.elementId.c_str(), 640, 480));
  REQUIRE(JsonBool(frame1, "ok", true));
  REQUIRE(JsonContains(frame1, "\"jobId\":\"job-1\""));
  REQUIRE(JsonNumber(frame1, "frame") == 1.0);
  REQUIRE(JsonNumber(frame1, "triangleCount") == 12.0);
  REQUIRE(JsonNumber(frame1, "vertexCount") == 8.0);
  REQUIRE(JsonNumber(frame1, "lightCount") == 2.0);
  REQUIRE(JsonBool(frame1, "offscreen", true));
  REQUIRE(JsonNumber(frame1, "width") == 640.0);
  REQUIRE(JsonNumber(frame1, "height") == 480.0);
  // 默认相机位于 (0,0,300) 看向原点。
  REQUIRE(JsonContains(frame1, "\"position\":{\"x\":0,\"y\":0,\"z\":300}"));

  const std::string frame2 =
      TakeAndFree(wb_3d_render(s3.elementId.c_str(), 640, 480));
  REQUIRE(JsonContains(frame2, "\"jobId\":\"job-2\""));
  REQUIRE(JsonNumber(frame2, "frame") == 2.0);

  // 非法视口尺寸：InvalidArgument。
  const std::string badSize =
      TakeAndFree(wb_3d_render(s3.elementId.c_str(), 0, 480));
  REQUIRE(JsonBool(badSize, "ok", false));
  REQUIRE(JsonContains(badSize, "InvalidArgument"));

  // 3) 渲染数据链路：3D 元素进入 Render3D 层、dirtyRect 与几何对齐。
  const std::string display = wb::invokeDomain(
      "render", "getDisplayList",
      "{\"pageId\":\"" + s3.scene.pageId + "\"}");
  REQUIRE(JsonBool(display, "ok", true));
  REQUIRE(JsonNumber(display, "count") == 1.0);
  REQUIRE(JsonContains(display, "\"type\":\"render3d\""));
  REQUIRE(JsonContains(display, "\"layer\":\"Render3D\""));
  // dirtyRect 键序为 height/width/x/y（字典序）：10,20 起 200×150。
  REQUIRE(JsonContains(display, "\"dirtyRect\":{\"height\":150"));
  REQUIRE(JsonContains(display, "\"width\":200"));

  // 4) layer 过滤联动：Dynamic 层为空。
  const std::string dynamicLayer = wb::invokeDomain(
      "render", "getDisplayList",
      "{\"pageId\":\"" + s3.scene.pageId + "\",\"layer\":\"Dynamic\"}");
  REQUIRE(JsonNumber(dynamicLayer, "count") == 0.0);
}

TEST_CASE("3d export: material, transform, obj/gltf and picking",
          "[integration][render3d]") {
  const Scene3d s3 = Build3d();
  REQUIRE(s3.scene.ok);

  // 1) 面颜色：合法/未知面/非法颜色。
  const std::string colored =
      TakeAndFree(wb_3d_set_face_color(s3.elementId.c_str(), 1, "#FF0000"));
  REQUIRE(JsonBool(colored, "ok", true));
  REQUIRE(JsonNumber(colored, "faceId") == 1.0);
  REQUIRE(JsonContains(colored, "\"color\":\"#FF0000\""));
  const std::string badFace =
      TakeAndFree(wb_3d_set_face_color(s3.elementId.c_str(), 99, "#FF0000"));
  REQUIRE(JsonBool(badFace, "ok", false));
  REQUIRE(JsonContains(badFace, "NotFound"));
  const std::string badColor =
      TakeAndFree(wb_3d_set_face_color(s3.elementId.c_str(), 1, "red"));
  REQUIRE(JsonBool(badColor, "ok", false));
  REQUIRE(JsonContains(badColor, "InvalidArgument"));

  // 2) 材质：与默认材质合并保留其它字段。
  const std::string material = TakeAndFree(wb_3d_set_material(
      s3.elementId.c_str(),
      "{\"metallic\":0.8,\"roughness\":0.2,\"baseColor\":\"#00FF00\"}"));
  REQUIRE(JsonBool(material, "ok", true));
  REQUIRE(JsonContains(material, "\"baseColor\":\"#00FF00\""));
  REQUIRE(JsonContains(material, "\"metallic\":0.8"));

  // 3) 光照：默认 2 盏 → 新增成为 3 盏；未知类型被拒。
  const std::string light = TakeAndFree(wb_3d_set_light(
      s3.elementId.c_str(),
      "{\"type\":\"point\",\"color\":\"#FFFF00\",\"intensity\":0.7}"));
  REQUIRE(JsonBool(light, "ok", true));
  REQUIRE(JsonNumber(light, "lightCount") == 3.0);
  const std::string badLight = TakeAndFree(wb_3d_set_light(
      s3.elementId.c_str(), "{\"type\":\"spot\",\"intensity\":0.5}"));
  REQUIRE(JsonBool(badLight, "ok", false));
  REQUIRE(JsonContains(badLight, "InvalidArgument"));

  // 4) 拾取链路：中心像素命中前面（默认变换）。
  const std::string pick =
      TakeAndFree(wb_3d_pick_surface(s3.elementId.c_str(), 320.0f, 240.0f));
  REQUIRE(JsonBool(pick, "ok", true));
  REQUIRE(JsonBool(pick, "hit", true));
  REQUIRE(JsonNumber(pick, "faceId") == 1.0);
  {
    // 相机 (0,0,300) 到盒体前面 z=+50：距离恰为 250。
    const double distance = JsonNumber(pick, "distance");
    REQUIRE(distance > 249.9);
    REQUIRE(distance < 250.1);
    const std::vector<double> zs = JsonNumbers(pick, "z");
    REQUIRE(zs.size() == 1);
    REQUIRE(zs[0] > 49.9);
    REQUIRE(zs[0] < 50.1);
  }

  // 5) 变换（放大 2 倍）→ obj 导出顶点为世界坐标 ±100。
  const std::string transformed = TakeAndFree(wb_3d_transform(
      s3.elementId.c_str(), "{\"scale\":{\"x\":2,\"y\":2,\"z\":2}}"));
  REQUIRE(JsonBool(transformed, "ok", true));
  REQUIRE(JsonContains(transformed, "\"scale\":{\"x\":2,\"y\":2,\"z\":2}"));

  const std::string obj = TakeAndFree(wb_3d_export(s3.elementId.c_str(), "obj"));
  REQUIRE(JsonBool(obj, "ok", true));
  REQUIRE(JsonContains(obj, "\"format\":\"obj\""));
  REQUIRE(JsonNumber(obj, "vertexCount") == 8.0);
  REQUIRE(JsonNumber(obj, "faceCount") == 6.0);
  REQUIRE(JsonContains(obj, "\"content\":\"# whiteboard 3D export\\n"));
  REQUIRE(JsonContains(obj, "# vertices: 8 faces: 6"));
  REQUIRE(JsonContains(obj, "v -100 -100 100"));
  REQUIRE(CountOccurrences(obj, "\\nv ") == 8);
  REQUIRE(CountOccurrences(obj, "\\nf ") == 12);

  // 6) gltf 导出：最小 glTF 2.0 结构（内嵌转义 JSON）。
  const std::string gltf =
      TakeAndFree(wb_3d_export(s3.elementId.c_str(), "gltf"));
  REQUIRE(JsonBool(gltf, "ok", true));
  REQUIRE(JsonContains(gltf, "\"format\":\"gltf\""));
  REQUIRE(JsonNumber(gltf, "vertexCount") == 8.0);
  REQUIRE(JsonContains(gltf, R"(\"generator\":\"whiteboard-core\")"));
  REQUIRE(JsonContains(gltf, R"(\"componentType\":5126)"));

  // 7) 非法格式与未知元素错误路径。
  const std::string badFormat =
      TakeAndFree(wb_3d_export(s3.elementId.c_str(), "fbx"));
  REQUIRE(JsonBool(badFormat, "ok", false));
  REQUIRE(JsonContains(badFormat, "InvalidArgument"));
  const std::string ghost =
      TakeAndFree(wb_3d_pick_surface("no-such-3d", 320.0f, 240.0f));
  REQUIRE(JsonBool(ghost, "ok", false));
  REQUIRE(JsonContains(ghost, "NotFound"));
}
