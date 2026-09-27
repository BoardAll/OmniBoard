// render3d/render3d.cpp — domain "render3d" (task package 1.6).
// Owns: core/src/render3d.
//
// Ops (《渲染引擎设计》§7): create, render, pickSurface, setFaceColor,
// setMaterial, setLight, transform, export, list.
//
// Headless CPU model of the 3D scene. Geometry is tessellated into a
// triangle mesh stored in element data (face colors, material, lights,
// camera and transform are JSON). `render` produces the render-job
// description the platform layer (bgfx) would consume; `pickSurface`
// performs a real Möller–Trumbore raycast against the tessellated mesh,
// so surface picking (§7.5) is verifiable without a GPU.
//
// Face ids are assigned per geometry in a fixed order (box: front=1,
// back=2, left=3, right=4, top=5, bottom=6; revolutions: sides then caps).

#include <algorithm>
#include <cctype>
#include <cmath>
#include <sstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "../model/scene_store.h"
#include "wb/ffi/domain.h"
#include "wb/platform/platform.h"

namespace wb {
namespace {

using scene::SceneStore;
using scene::PageRec;

constexpr double kPi = 3.14159265358979323846;
constexpr int kDefaultViewportWidth = 640;
constexpr int kDefaultViewportHeight = 480;
constexpr const char* kDefaultFaceColor = "#90A4AE";

nlohmann::json ParseArgs(const std::string& argsJson) {
  if (argsJson.empty()) return nlohmann::json::object();
  auto parsed = nlohmann::json::parse(argsJson, nullptr, false);
  return parsed.is_object() ? parsed : nlohmann::json::object();
}

void Renumber(std::vector<nlohmann::json>& elements) {
  for (std::size_t i = 0; i < elements.size(); ++i) {
    elements[i]["zIndex"] = static_cast<int>(i);
  }
}

std::string ToLower(std::string text) {
  for (char& ch : text) {
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  }
  return text;
}

bool IsColorString(const std::string& color) {
  if (color.size() != 7 && color.size() != 9) return false;
  if (color[0] != '#') return false;
  for (std::size_t i = 1; i < color.size(); ++i) {
    if (!std::isxdigit(static_cast<unsigned char>(color[i]))) return false;
  }
  return true;
}

/// Picks the element id from args: `elementId` first, then `render3dId`.
std::string ElementIdArg(const nlohmann::json& args) {
  const std::string elementId = args.value("elementId", std::string());
  if (!elementId.empty()) return elementId;
  return args.value("render3dId", std::string());
}

// --- small vector helpers ---------------------------------------------------

struct Vec3 {
  double x = 0.0;
  double y = 0.0;
  double z = 0.0;
};

Vec3 VAdd(const Vec3& a, const Vec3& b) {
  return {a.x + b.x, a.y + b.y, a.z + b.z};
}
Vec3 VSub(const Vec3& a, const Vec3& b) {
  return {a.x - b.x, a.y - b.y, a.z - b.z};
}
Vec3 VScale(const Vec3& v, double s) { return {v.x * s, v.y * s, v.z * s}; }
double VDot(const Vec3& a, const Vec3& b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
Vec3 VCross(const Vec3& a, const Vec3& b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
Vec3 VNorm(const Vec3& v) {
  const double len = std::sqrt(VDot(v, v));
  if (len < 1e-12) return {};
  return {v.x / len, v.y / len, v.z / len};
}

Vec3 QueryVec3(const nlohmann::json& object, const char* key,
               const Vec3& fallback) {
  if (!object.contains(key) || !object[key].is_object()) return fallback;
  const nlohmann::json& value = object[key];
  return {value.value("x", fallback.x), value.value("y", fallback.y),
          value.value("z", fallback.z)};
}

nlohmann::json Vec3Json(const Vec3& v) {
  nlohmann::json out;
  out["x"] = v.x;
  out["y"] = v.y;
  out["z"] = v.z;
  return out;
}

// --- geometry builders ------------------------------------------------------

double Param(const nlohmann::json& geometry, const char* key, double fallback) {
  if (geometry.contains(key) && geometry[key].is_number()) {
    return geometry[key].get<double>();
  }
  return fallback;
}

int SegmentCount(const nlohmann::json& geometry, const char* key, int fallback) {
  const double raw = Param(geometry, key, static_cast<double>(fallback));
  const int count = static_cast<int>(raw);
  return std::max(3, std::min(count, 256));
}

struct Face {
  int id = 0;
  std::vector<int> indices;
};

struct Mesh {
  std::vector<Vec3> vertices;
  std::vector<Face> faces;
};

void PushFace(Mesh& mesh, std::vector<int> indices) {
  Face face;
  face.id = static_cast<int>(mesh.faces.size()) + 1;
  face.indices = std::move(indices);
  mesh.faces.push_back(std::move(face));
}

Mesh BuildBox(const nlohmann::json& geometry) {
  const double w = Param(geometry, "width", 100.0);
  const double h = Param(geometry, "height", 100.0);
  const double d = Param(geometry, "depth", 100.0);
  const double hx = w / 2.0;
  const double hy = h / 2.0;
  const double hz = d / 2.0;
  Mesh mesh;
  mesh.vertices = {{-hx, -hy, hz}, {hx, -hy, hz},  {hx, hy, hz},
                   {-hx, hy, hz},  {hx, -hy, -hz}, {-hx, -hy, -hz},
                   {-hx, hy, -hz}, {hx, hy, -hz}};
  PushFace(mesh, {0, 1, 2, 3});  // front (z+)
  PushFace(mesh, {4, 5, 6, 7});  // back (z-)
  PushFace(mesh, {5, 0, 3, 6});  // left (x-)
  PushFace(mesh, {1, 4, 7, 2});  // right (x+)
  PushFace(mesh, {3, 2, 7, 6});  // top (y+)
  PushFace(mesh, {0, 5, 4, 1});  // bottom (y-)
  return mesh;
}

/// Cylinder / cone / prism / pyramid: a ring of `segments` points, optionally
/// closed by an apex (cone-like) or a second ring (cylinder-like).
Mesh BuildRevolution(const nlohmann::json& geometry, int segments, bool cone) {
  const double radius = Param(geometry, "radius", 50.0);
  const double height = Param(geometry, "height", 100.0);
  const double hy = height / 2.0;
  Mesh mesh;
  std::vector<int> bottom;
  std::vector<int> top;
  for (int i = 0; i < segments; ++i) {
    const double angle = 2.0 * kPi * static_cast<double>(i) /
                         static_cast<double>(segments);
    const double x = radius * std::cos(angle);
    const double z = radius * std::sin(angle);
    bottom.push_back(static_cast<int>(mesh.vertices.size()));
    mesh.vertices.push_back({x, -hy, z});
    if (!cone) {
      top.push_back(static_cast<int>(mesh.vertices.size()));
      mesh.vertices.push_back({x, hy, z});
    }
  }
  int apex = -1;
  if (cone) {
    apex = static_cast<int>(mesh.vertices.size());
    mesh.vertices.push_back({0.0, hy, 0.0});
  }
  for (int i = 0; i < segments; ++i) {
    const int next = (i + 1) % segments;
    if (cone) {
      PushFace(mesh, {bottom[i], bottom[next], apex});
    } else {
      PushFace(mesh, {bottom[i], bottom[next], top[next], top[i]});
    }
  }
  if (!cone) {
    std::vector<int> topRing = top;
    PushFace(mesh, std::move(topRing));
  }
  std::vector<int> bottomRing(bottom.rbegin(), bottom.rend());
  PushFace(mesh, std::move(bottomRing));
  return mesh;
}

Mesh BuildSphere(const nlohmann::json& geometry) {
  const double radius = Param(geometry, "radius", 50.0);
  const int latSegments = SegmentCount(
      geometry, geometry.contains("latitudeSegments") ? "latitudeSegments"
                                                      : "latSegments",
      12);
  const int lonSegments = SegmentCount(
      geometry, geometry.contains("longitudeSegments") ? "longitudeSegments"
                                                       : "lonSegments",
      24);
  Mesh mesh;
  for (int lat = 0; lat <= latSegments; ++lat) {
    const double theta = kPi * static_cast<double>(lat) /
                         static_cast<double>(latSegments);
    const double y = radius * std::cos(theta);
    const double ringRadius = radius * std::sin(theta);
    for (int lon = 0; lon <= lonSegments; ++lon) {
      const double phi = 2.0 * kPi * static_cast<double>(lon) /
                         static_cast<double>(lonSegments);
      mesh.vertices.push_back(
          {ringRadius * std::cos(phi), y, ringRadius * std::sin(phi)});
    }
  }
  const int stride = lonSegments + 1;
  for (int lat = 0; lat < latSegments; ++lat) {
    for (int lon = 0; lon < lonSegments; ++lon) {
      const int a = lat * stride + lon;
      const int b = a + stride;
      PushFace(mesh, {a, a + 1, b + 1, b});
    }
  }
  return mesh;
}

Mesh BuildTorus(const nlohmann::json& geometry) {
  const double mainRadius = Param(
      geometry, "mainRadius", Param(geometry, "radius", 60.0));
  const double tubeRadius = Param(geometry, "tubeRadius", 20.0);
  const int segments = SegmentCount(geometry, "segments", 32);
  const int tubeSegments = SegmentCount(geometry, "tubeSegments", 16);
  Mesh mesh;
  for (int i = 0; i <= segments; ++i) {
    const double u = 2.0 * kPi * static_cast<double>(i) /
                     static_cast<double>(segments);
    for (int j = 0; j <= tubeSegments; ++j) {
      const double v = 2.0 * kPi * static_cast<double>(j) /
                       static_cast<double>(tubeSegments);
      const double ring = mainRadius + tubeRadius * std::cos(v);
      mesh.vertices.push_back(
          {ring * std::cos(u), tubeRadius * std::sin(v), ring * std::sin(u)});
    }
  }
  const int stride = tubeSegments + 1;
  for (int i = 0; i < segments; ++i) {
    for (int j = 0; j < tubeSegments; ++j) {
      const int a = i * stride + j;
      const int b = a + stride;
      PushFace(mesh, {a, b, b + 1, a + 1});
    }
  }
  return mesh;
}

Mesh MeshForData(const nlohmann::json& data) {
  nlohmann::json geometry = nlohmann::json::object();
  if (data.contains("geometry") && data["geometry"].is_object()) {
    geometry = data["geometry"];
  }
  const std::string type = ToLower(geometry.value("type", std::string("box")));
  if (type == "cylinder") return BuildRevolution(geometry, 16, false);
  if (type == "cone") return BuildRevolution(geometry, 16, true);
  if (type == "prism") {
    return BuildRevolution(geometry, SegmentCount(geometry, "sides", 6), false);
  }
  if (type == "pyramid") {
    return BuildRevolution(geometry, SegmentCount(geometry, "sides", 4), true);
  }
  if (type == "sphere") return BuildSphere(geometry);
  if (type == "torus") return BuildTorus(geometry);
  return BuildBox(geometry);
}

Vec3 FaceNormal(const Mesh& mesh, const Face& face) {
  if (face.indices.size() < 3) return {};
  const Vec3& a = mesh.vertices[static_cast<std::size_t>(face.indices[0])];
  const Vec3& b = mesh.vertices[static_cast<std::size_t>(face.indices[1])];
  const Vec3& c = mesh.vertices[static_cast<std::size_t>(face.indices[2])];
  return VNorm(VCross(VSub(b, a), VSub(c, a)));
}

// --- transforms and camera --------------------------------------------------

Vec3 ApplyTransform(const Vec3& vertex, const nlohmann::json& transform) {
  const Vec3 scale = QueryVec3(transform, "scale", {1.0, 1.0, 1.0});
  const Vec3 rotation = QueryVec3(transform, "rotation", {0.0, 0.0, 0.0});
  const Vec3 position = QueryVec3(transform, "position", {0.0, 0.0, 0.0});
  Vec3 p{vertex.x * scale.x, vertex.y * scale.y, vertex.z * scale.z};
  // Euler XYZ, degrees.
  const double rx = rotation.x * kPi / 180.0;
  const double ry = rotation.y * kPi / 180.0;
  const double rz = rotation.z * kPi / 180.0;
  const double cx = std::cos(rx);
  const double sx = std::sin(rx);
  const double cy = std::cos(ry);
  const double sy = std::sin(ry);
  const double cz = std::cos(rz);
  const double sz = std::sin(rz);
  p = {p.x, p.y * cx - p.z * sx, p.y * sx + p.z * cx};
  p = {p.x * cy + p.z * sy, p.y, -p.x * sy + p.z * cy};
  p = {p.x * cz - p.y * sz, p.x * sz + p.y * cz, p.z};
  return {p.x + position.x, p.y + position.y, p.z + position.z};
}

struct Camera {
  Vec3 position{0.0, 0.0, 300.0};
  Vec3 target{0.0, 0.0, 0.0};
  Vec3 up{0.0, 1.0, 0.0};
  double fovDegrees = 45.0;
};

Camera QueryCamera(const nlohmann::json& data) {
  Camera camera;
  if (data.contains("camera") && data["camera"].is_object()) {
    const nlohmann::json& raw = data["camera"];
    camera.position = QueryVec3(raw, "position", camera.position);
    camera.target = QueryVec3(raw, "target", camera.target);
    camera.up = QueryVec3(raw, "up", camera.up);
    camera.fovDegrees = raw.value("fov", camera.fovDegrees);
  }
  return camera;
}

bool RayTriangle(const Vec3& origin, const Vec3& direction, const Vec3& a,
                 const Vec3& b, const Vec3& c, double* tHit) {
  const Vec3 e1 = VSub(b, a);
  const Vec3 e2 = VSub(c, a);
  const Vec3 p = VCross(direction, e2);
  const double det = VDot(e1, p);
  if (std::fabs(det) < 1e-12) return false;
  const double inv = 1.0 / det;
  const Vec3 tv = VSub(origin, a);
  const double u = VDot(tv, p) * inv;
  if (u < -1e-9 || u > 1.0 + 1e-9) return false;
  const Vec3 q = VCross(tv, e1);
  const double v = VDot(direction, q) * inv;
  if (v < -1e-9 || u + v > 1.0 + 1e-9) return false;
  const double t = VDot(e2, q) * inv;
  if (t <= 1e-9) return false;
  *tHit = t;
  return true;
}

// --- defaults ---------------------------------------------------------------

nlohmann::json DefaultCamera() {
  return nlohmann::json::parse(
      R"({"position":{"x":0,"y":0,"z":300},"target":{"x":0,"y":0,"z":0},)"
      R"("up":{"x":0,"y":1,"z":0},"fov":45.0,"near":1.0,"far":10000.0,)"
      R"("orthographic":false})");
}

nlohmann::json DefaultMaterial() {
  return nlohmann::json::parse(
      R"({"baseColor":"#8899AA","metallic":0.0,"roughness":0.6,)"
      R"("opacity":1.0,"wireframe":false})");
}

nlohmann::json DefaultTransform() {
  return nlohmann::json::parse(
      R"({"position":{"x":0,"y":0,"z":0},"rotation":{"x":0,"y":0,"z":0},)"
      R"("scale":{"x":1,"y":1,"z":1}})");
}

nlohmann::json DefaultLights() {
  return nlohmann::json::parse(
      R"([{"type":"ambient","color":"#FFFFFF","intensity":0.4},)"
      R"({"type":"directional","color":"#FFFFFF","intensity":0.8,)"
      R"("direction":{"x":-0.5,"y":-1.0,"z":-0.5}}])");
}

bool ValidLight(const nlohmann::json& light, std::string* error) {
  if (!light.is_object()) {
    *error = "light must be an object";
    return false;
  }
  const std::string type = light.value("type", std::string());
  if (type != "ambient" && type != "directional" && type != "point") {
    *error = "unknown light type: " +
             (type.empty() ? std::string("(missing)") : type);
    return false;
  }
  if (light.contains("color") &&
      (!light["color"].is_string() ||
       !IsColorString(light["color"].get<std::string>()))) {
    *error = "invalid light color";
    return false;
  }
  if (light.contains("intensity") && !light["intensity"].is_number()) {
    *error = "light intensity must be a number";
    return false;
  }
  return true;
}

/// Normalizes freshly created element data and validates user input.
bool NormalizeData(nlohmann::json& data, std::string* error) {
  // Geometry: object or shorthand string, e.g. "sphere".
  nlohmann::json geometry = nlohmann::json::object();
  if (data.contains("geometry")) {
    if (data["geometry"].is_string()) {
      geometry = nlohmann::json{{"type", data["geometry"].get<std::string>()}};
    } else if (data["geometry"].is_object()) {
      geometry = data["geometry"];
    } else {
      *error = "geometry must be an object or string";
      return false;
    }
  }
  const std::string type = ToLower(geometry.value("type", std::string("box")));
  static const char* kGeometries[] = {"box",     "cylinder", "cone", "sphere",
                                      "prism",   "pyramid",  "torus"};
  bool known = false;
  for (const char* candidate : kGeometries) {
    if (type == candidate) known = true;
  }
  if (!known) {
    *error = "unknown geometry type: " + type;
    return false;
  }
  geometry["type"] = type;
  data["geometry"] = std::move(geometry);

  nlohmann::json camera = DefaultCamera();
  if (data.contains("camera") && data["camera"].is_object()) {
    for (auto it = data["camera"].begin(); it != data["camera"].end(); ++it) {
      camera[it.key()] = it.value();
    }
  }
  data["camera"] = std::move(camera);

  nlohmann::json material = DefaultMaterial();
  if (data.contains("material") && data["material"].is_object()) {
    for (auto it = data["material"].begin(); it != data["material"].end();
         ++it) {
      material[it.key()] = it.value();
    }
  }
  for (const char* key : {"metallic", "roughness", "opacity"}) {
    if (material.contains(key)) {
      if (!material[key].is_number()) {
        *error = std::string("material.") + key + " must be a number";
        return false;
      }
      const double value = material[key].get<double>();
      if (value < 0.0 || value > 1.0) {
        *error = std::string("material.") + key + " must be within [0, 1]";
        return false;
      }
    }
  }
  if (material.contains("baseColor") &&
      (!material["baseColor"].is_string() ||
       !IsColorString(material["baseColor"].get<std::string>()))) {
    *error = "invalid material baseColor";
    return false;
  }
  data["material"] = std::move(material);

  if (data.contains("lights")) {
    if (!data["lights"].is_array()) {
      *error = "lights must be an array";
      return false;
    }
    for (const nlohmann::json& light : data["lights"]) {
      if (!ValidLight(light, error)) return false;
    }
    if (data["lights"].empty()) data["lights"] = DefaultLights();
  } else {
    data["lights"] = DefaultLights();
  }

  nlohmann::json transform = DefaultTransform();
  if (data.contains("transform") && data["transform"].is_object()) {
    for (auto it = data["transform"].begin(); it != data["transform"].end();
         ++it) {
      transform[it.key()] = it.value();
    }
  }
  data["transform"] = std::move(transform);

  nlohmann::json viewport = nlohmann::json::object();
  viewport["width"] = kDefaultViewportWidth;
  viewport["height"] = kDefaultViewportHeight;
  if (data.contains("viewport") && data["viewport"].is_object()) {
    for (auto it = data["viewport"].begin(); it != data["viewport"].end();
         ++it) {
      viewport[it.key()] = it.value();
    }
  }
  data["viewport"] = std::move(viewport);

  if (data.contains("faceColors")) {
    if (!data["faceColors"].is_object()) {
      *error = "faceColors must be an object";
      return false;
    }
    for (auto it = data["faceColors"].begin(); it != data["faceColors"].end();
         ++it) {
      if (!it.value().is_string() ||
          !IsColorString(it.value().get<std::string>())) {
        *error = "invalid face color for face " + it.key();
        return false;
      }
    }
  } else {
    data["faceColors"] = nlohmann::json::object();
  }

  if (!data.contains("frame") || !data["frame"].is_number_integer()) {
    data["frame"] = 0;
  }
  return true;
}

// --- serialization ----------------------------------------------------------

nlohmann::json FacesJson(const Mesh& mesh, const nlohmann::json& data) {
  nlohmann::json faceColors = nlohmann::json::object();
  if (data.contains("faceColors") && data["faceColors"].is_object()) {
    faceColors = data["faceColors"];
  }
  std::string baseColor = kDefaultFaceColor;
  if (data.contains("material") && data["material"].is_object()) {
    baseColor = data["material"].value("baseColor", baseColor);
  }
  nlohmann::json faces = nlohmann::json::array();
  for (const Face& face : mesh.faces) {
    nlohmann::json item;
    item["id"] = face.id;
    item["indices"] = face.indices;
    item["color"] = faceColors.value(std::to_string(face.id), baseColor);
    item["normal"] = Vec3Json(FaceNormal(mesh, face));
    faces.push_back(std::move(item));
  }
  return faces;
}

int TriangleIndexCount(const Mesh& mesh) {
  int count = 0;
  for (const Face& face : mesh.faces) {
    if (face.indices.size() >= 3) {
      count += static_cast<int>(face.indices.size() - 2) * 3;
    }
  }
  return count;
}

class Render3dDomain : public DomainHandler {
 public:
  std::string name() const override { return "render3d"; }

  std::string handle(const std::string& op,
                     const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "create") return Create(args);
    if (op == "render") return Render(args);
    if (op == "pickSurface" || op == "pick_surface") return PickSurface(args);
    if (op == "setFaceColor" || op == "set_face_color") {
      return SetFaceColor(args);
    }
    if (op == "setMaterial" || op == "set_material") return SetMaterial(args);
    if (op == "setLight" || op == "set_light" || op == "setLights" ||
        op == "set_lights") {
      return SetLight(args);
    }
    if (op == "transform") return Transform(args);
    if (op == "export") return Export(args);
    if (op == "list") return List(args);
    return domainError("NotFound", "unknown render3d op: " + op);
  }

 private:
  /// Finds a "render3d" element; fills errorCode/errorMessage on failure.
  nlohmann::json* Find(SceneStore& store, const std::string& elementId,
                       std::string* errorCode, std::string* errorMessage) {
    const scene::ElementLocation location = store.findElement(elementId);
    if (location.index < 0) {
      *errorCode = "NotFound";
      *errorMessage = "unknown element: " + elementId;
      return nullptr;
    }
    if (location.page->locked) {
      *errorCode = "Conflict";
      *errorMessage = "page is locked: " + location.page->id;
      return nullptr;
    }
    nlohmann::json& element =
        location.page->elements[static_cast<std::size_t>(location.index)];
    const std::string type = element.value("type", std::string());
    if (type != "render3d" && type != "3d") {
      *errorCode = "InvalidArgument";
      *errorMessage = "element is not a 3D element: " + elementId;
      return nullptr;
    }
    return &element;
  }

  static nlohmann::json DefaultData() {
    nlohmann::json data;
    data["geometry"] = nlohmann::json::parse(R"({"type":"box"})");
    return data;
  }

  // --- ops ------------------------------------------------------------------
  std::string Create(const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    PageRec* page = SceneStore::instance().findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    if (page->locked) {
      return domainError("Conflict", "page is locked: " + pageId);
    }
    nlohmann::json element = args.value("element", nlohmann::json::object());
    if (!element.is_object()) element = nlohmann::json::object();
    element["type"] = "render3d";

    nlohmann::json data = DefaultData();
    if (element.contains("data") && element["data"].is_object()) {
      for (auto it = element["data"].begin(); it != element["data"].end();
           ++it) {
        data[it.key()] = it.value();
      }
    }
    if (data.contains("geometry") && data["geometry"].is_string()) {
      data["geometry"] =
          nlohmann::json{{"type", data["geometry"].get<std::string>()}};
    }
    std::string message;
    if (!NormalizeData(data, &message)) {
      return domainError("InvalidArgument", message);
    }
    element["data"] = std::move(data);

    std::string elementId = element.value("id", std::string());
    if (elementId.empty()) elementId = SceneStore::instance().newElementId();
    const std::int64_t now = timeMillis();
    element["id"] = elementId;
    element["pageId"] = pageId;
    element["createdAt"] = element.value("createdAt", now);
    element["updatedAt"] = now;
    element["rotation"] = element.value("rotation", 0.0f);
    element["opacity"] = element.value("opacity", 1.0f);
    element["locked"] = element.value("locked", false);

    int index = static_cast<int>(page->elements.size());
    if (element.contains("zIndex") && element["zIndex"].is_number_integer()) {
      index = std::max(0, std::min(element["zIndex"].get<int>(), index));
    }
    element["zIndex"] = index;
    page->elements.insert(page->elements.begin() + index, std::move(element));
    Renumber(page->elements);

    nlohmann::json& created = page->elements[static_cast<std::size_t>(index)];
    const Mesh mesh = MeshForData(created["data"]);
    nlohmann::json result;
    result["element"] = created;
    result["elementId"] = elementId;
    result["pageId"] = pageId;
    result["type"] = "render3d";
    result["geometryType"] =
        created["data"]["geometry"].value("type", std::string("box"));
    result["vertexCount"] = static_cast<int>(mesh.vertices.size());
    result["faceCount"] = static_cast<int>(mesh.faces.size());
    result["faces"] = FacesJson(mesh, created["data"]);
    return domainOk(result.dump());
  }

  std::string Render(const nlohmann::json& args) {
    const std::string elementId = ElementIdArg(args);
    const int width = args.value("width", kDefaultViewportWidth);
    const int height = args.value("height", kDefaultViewportHeight);
    if (width <= 0 || height <= 0) {
      return domainError("InvalidArgument",
                         "width and height must be positive");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& data = (*element)["data"];
    data["viewport"]["width"] = width;
    data["viewport"]["height"] = height;
    const int frame = data.value("frame", 0) + 1;
    data["frame"] = frame;
    (*element)["updatedAt"] = timeMillis();

    const Mesh mesh = MeshForData(data);
    nlohmann::json result;
    result["elementId"] = elementId;
    result["jobId"] = "job-" + std::to_string(frame);
    result["frame"] = frame;
    result["width"] = width;
    result["height"] = height;
    result["vertexCount"] = static_cast<int>(mesh.vertices.size());
    result["faceCount"] = static_cast<int>(mesh.faces.size());
    result["triangleCount"] = TriangleIndexCount(mesh) / 3;
    result["camera"] = data["camera"];
    result["lightCount"] = static_cast<int>(data["lights"].size());
    result["offscreen"] = true;
    return domainOk(result.dump());
  }

  std::string PickSurface(const nlohmann::json& args) {
    const std::string elementId = ElementIdArg(args);
    if (!args.contains("x") || !args["x"].is_number() ||
        !args.contains("y") || !args["y"].is_number()) {
      return domainError("InvalidArgument", "args.x and args.y are required");
    }
    const double x = args["x"].get<double>();
    const double y = args["y"].get<double>();
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    const nlohmann::json& data = (*element)["data"];
    const int width = data["viewport"].value("width", kDefaultViewportWidth);
    const int height =
        data["viewport"].value("height", kDefaultViewportHeight);
    const Camera camera = QueryCamera(data);
    const Mesh local = MeshForData(data);
    const nlohmann::json& transform = data["transform"];

    std::vector<Vec3> world;
    world.reserve(local.vertices.size());
    for (const Vec3& vertex : local.vertices) {
      world.push_back(ApplyTransform(vertex, transform));
    }

    const Vec3 forward = VNorm(VSub(camera.target, camera.position));
    const Vec3 right = VNorm(VCross(forward, camera.up));
    const Vec3 up = VCross(right, forward);
    const double aspect = static_cast<double>(width) / static_cast<double>(height);
    const double tanHalf = std::tan(camera.fovDegrees * kPi / 360.0);
    const double ndcX = (x / static_cast<double>(width)) * 2.0 - 1.0;
    const double ndcY = 1.0 - (y / static_cast<double>(height)) * 2.0;
    const Vec3 direction = VNorm(
        VAdd(forward, VAdd(VScale(right, ndcX * tanHalf * aspect),
                           VScale(up, ndcY * tanHalf))));

    double bestT = 0.0;
    int bestFace = -1;
    for (const Face& face : local.faces) {
      if (face.indices.size() < 3) continue;
      const Vec3& a = world[static_cast<std::size_t>(face.indices[0])];
      for (std::size_t i = 1; i + 1 < face.indices.size(); ++i) {
        const Vec3& b = world[static_cast<std::size_t>(face.indices[i])];
        const Vec3& c = world[static_cast<std::size_t>(face.indices[i + 1])];
        double t = 0.0;
        if (RayTriangle(camera.position, direction, a, b, c, &t) &&
            (bestFace < 0 || t < bestT)) {
          bestT = t;
          bestFace = face.id;
        }
      }
    }

    nlohmann::json result;
    result["elementId"] = elementId;
    result["viewport"] = data["viewport"];
    if (bestFace < 0) {
      result["hit"] = false;
      return domainOk(result.dump());
    }
    const Vec3 point = VAdd(camera.position, VScale(direction, bestT));
    result["hit"] = true;
    result["faceId"] = bestFace;
    result["distance"] = bestT;
    result["point"] = Vec3Json(point);
    return domainOk(result.dump());
  }

  std::string SetFaceColor(const nlohmann::json& args) {
    const std::string elementId = ElementIdArg(args);
    if (!args.contains("faceId") || !args["faceId"].is_number_integer()) {
      return domainError("InvalidArgument", "args.faceId is required");
    }
    const int faceId = args["faceId"].get<int>();
    const std::string color = args.value("color", std::string());
    if (!IsColorString(color)) {
      return domainError("InvalidArgument",
                         "args.color must be #RRGGBB or #AARRGGBB");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& data = (*element)["data"];
    const Mesh mesh = MeshForData(data);
    bool exists = false;
    for (const Face& face : mesh.faces) {
      if (face.id == faceId) exists = true;
    }
    if (!exists) {
      return domainError("NotFound", "unknown face: " + std::to_string(faceId));
    }
    data["faceColors"][std::to_string(faceId)] = color;
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["elementId"] = elementId;
    result["faceId"] = faceId;
    result["color"] = color;
    return domainOk(result.dump());
  }

  std::string SetMaterial(const nlohmann::json& args) {
    const std::string elementId = ElementIdArg(args);
    nlohmann::json material = args.value("material", nlohmann::json::object());
    if (!material.is_object() || material.empty()) {
      return domainError("InvalidArgument", "args.material is required");
    }
    for (const char* key : {"metallic", "roughness", "opacity"}) {
      if (material.contains(key)) {
        if (!material[key].is_number()) {
          return domainError("InvalidArgument",
                             std::string("material.") + key +
                                 " must be a number");
        }
        const double value = material[key].get<double>();
        if (value < 0.0 || value > 1.0) {
          return domainError("InvalidArgument",
                             std::string("material.") + key +
                                 " must be within [0, 1]");
        }
      }
    }
    if (material.contains("baseColor") &&
        (!material["baseColor"].is_string() ||
         !IsColorString(material["baseColor"].get<std::string>()))) {
      return domainError("InvalidArgument", "invalid material baseColor");
    }

    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& current = (*element)["data"]["material"];
    for (auto it = material.begin(); it != material.end(); ++it) {
      current[it.key()] = it.value();
    }
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["elementId"] = elementId;
    result["material"] = current;
    return domainOk(result.dump());
  }

  std::string SetLight(const nlohmann::json& args) {
    const std::string elementId = ElementIdArg(args);
    const bool batch =
        args.contains("lights") && args["lights"].is_array() &&
        !args["lights"].empty();
    nlohmann::json light = args.value("light", nlohmann::json::object());
    if (!batch) {
      if (!light.is_object() || light.empty()) {
        return domainError("InvalidArgument",
                           "args.light or args.lights is required");
      }
      std::string message;
      if (!ValidLight(light, &message)) {
        return domainError("InvalidArgument", message);
      }
    } else {
      std::string message;
      for (const nlohmann::json& item : args["lights"]) {
        if (!ValidLight(item, &message)) {
          return domainError("InvalidArgument", message);
        }
      }
    }

    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& lights = (*element)["data"]["lights"];
    if (batch) {
      lights = args["lights"];
    } else if (args.contains("index")) {
      if (!args["index"].is_number_integer()) {
        return domainError("InvalidArgument", "args.index must be an integer");
      }
      const int index = args["index"].get<int>();
      if (index < 0 || index >= static_cast<int>(lights.size())) {
        return domainError("NotFound",
                           "light index out of range: " +
                               std::to_string(index));
      }
      lights[static_cast<std::size_t>(index)] = light;
    } else {
      lights.push_back(light);
    }
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["elementId"] = elementId;
    result["lights"] = lights;
    result["lightCount"] = static_cast<int>(lights.size());
    return domainOk(result.dump());
  }

  std::string Transform(const nlohmann::json& args) {
    const std::string elementId = ElementIdArg(args);
    nlohmann::json transform = args.value("transform", nlohmann::json::object());
    if (!transform.is_object() || transform.empty()) {
      return domainError("InvalidArgument", "args.transform is required");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& current = (*element)["data"]["transform"];
    for (auto it = transform.begin(); it != transform.end(); ++it) {
      current[it.key()] = it.value();
    }
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["elementId"] = elementId;
    result["transform"] = current;
    return domainOk(result.dump());
  }

  std::string Export(const nlohmann::json& args) {
    const std::string elementId = ElementIdArg(args);
    const std::string format =
        ToLower(args.value("format", std::string("obj")));
    if (format != "obj" && format != "gltf") {
      return domainError("InvalidArgument", "unknown export format: " + format);
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    const nlohmann::json& data = (*element)["data"];
    const Mesh local = MeshForData(data);
    std::vector<Vec3> world;
    world.reserve(local.vertices.size());
    for (const Vec3& vertex : local.vertices) {
      world.push_back(ApplyTransform(vertex, data["transform"]));
    }

    nlohmann::json result;
    result["elementId"] = elementId;
    result["format"] = format;
    result["vertexCount"] = static_cast<int>(world.size());
    result["faceCount"] = static_cast<int>(local.faces.size());
    if (format == "obj") {
      std::ostringstream out;
      out << "# whiteboard 3D export\n";
      out << "# geometry: "
          << data["geometry"].value("type", std::string("box")) << "\n";
      out << "# vertices: " << world.size() << " faces: " << local.faces.size()
          << "\n";
      for (const Vec3& vertex : world) {
        out << "v " << vertex.x << " " << vertex.y << " " << vertex.z << "\n";
      }
      for (const Face& face : local.faces) {
        for (std::size_t i = 1; i + 1 < face.indices.size(); ++i) {
          out << "f " << face.indices[0] + 1 << " " << face.indices[i] + 1
              << " " << face.indices[i + 1] + 1 << "\n";
        }
      }
      result["content"] = out.str();
      return domainOk(result.dump());
    }

    // Minimal glTF 2.0 structure; binary buffers are produced by the
    // platform exporter, the structural JSON is stable here.
    nlohmann::json positions = nlohmann::json::array();
    Vec3 min = world.empty() ? Vec3{} : world.front();
    Vec3 max = min;
    for (const Vec3& vertex : world) {
      positions.push_back(vertex.x);
      positions.push_back(vertex.y);
      positions.push_back(vertex.z);
      min = {std::min(min.x, vertex.x), std::min(min.y, vertex.y),
             std::min(min.z, vertex.z)};
      max = {std::max(max.x, vertex.x), std::max(max.y, vertex.y),
             std::max(max.z, vertex.z)};
    }
    std::vector<unsigned int> indices;
    for (const Face& face : local.faces) {
      for (std::size_t i = 1; i + 1 < face.indices.size(); ++i) {
        indices.push_back(static_cast<unsigned int>(face.indices[0]));
        indices.push_back(static_cast<unsigned int>(face.indices[i]));
        indices.push_back(static_cast<unsigned int>(face.indices[i + 1]));
      }
    }
    const int vertexCount = static_cast<int>(world.size());
    const int indexCount = static_cast<int>(indices.size());
    nlohmann::json gltf;
    gltf["asset"] = nlohmann::json::parse(
        R"({"version":"2.0","generator":"whiteboard-core"})");
    gltf["scene"] = 0;
    gltf["scenes"] = nlohmann::json::array(
        {nlohmann::json::parse(R"({"nodes":[0]})")});
    nlohmann::json node;
    node["mesh"] = 0;
    node["name"] = elementId;
    gltf["nodes"] = nlohmann::json::array({std::move(node)});
    nlohmann::json primitive;
    primitive["attributes"] = nlohmann::json::parse(R"({"POSITION":0})");
    primitive["indices"] = 1;
    primitive["mode"] = 4;
    nlohmann::json meshJson;
    meshJson["name"] = data["geometry"].value("type", std::string("box"));
    meshJson["primitives"] = nlohmann::json::array({std::move(primitive)});
    gltf["meshes"] = nlohmann::json::array({std::move(meshJson)});
    nlohmann::json positionAccessor;
    positionAccessor["bufferView"] = 0;
    positionAccessor["componentType"] = 5126;
    positionAccessor["count"] = vertexCount;
    positionAccessor["type"] = "VEC3";
    positionAccessor["min"] = nlohmann::json::array({min.x, min.y, min.z});
    positionAccessor["max"] = nlohmann::json::array({max.x, max.y, max.z});
    nlohmann::json indexAccessor;
    indexAccessor["bufferView"] = 1;
    indexAccessor["componentType"] = 5125;
    indexAccessor["count"] = indexCount;
    indexAccessor["type"] = "SCALAR";
    gltf["accessors"] =
        nlohmann::json::array({std::move(positionAccessor),
                               std::move(indexAccessor)});
    nlohmann::json positionView;
    positionView["buffer"] = 0;
    positionView["byteOffset"] = 0;
    positionView["byteLength"] = vertexCount * 12;
    nlohmann::json indexView;
    indexView["buffer"] = 0;
    indexView["byteOffset"] = vertexCount * 12;
    indexView["byteLength"] = indexCount * 4;
    gltf["bufferViews"] = nlohmann::json::array(
        {std::move(positionView), std::move(indexView)});
    gltf["buffers"] = nlohmann::json::array(
        {nlohmann::json::parse("{\"byteLength\":" +
                               std::to_string(vertexCount * 12 +
                                              indexCount * 4) +
                               "}")});
    result["content"] = gltf.dump();
    return domainOk(result.dump());
  }

  std::string List(const nlohmann::json& args) {
    const std::string pageId = args.value("pageId", std::string());
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    PageRec* page = SceneStore::instance().findPage(pageId, nullptr);
    if (page == nullptr) {
      return domainError("NotFound", "unknown page: " + pageId);
    }
    nlohmann::json elements = nlohmann::json::array();
    for (const nlohmann::json& element : page->elements) {
      const std::string type = element.value("type", std::string());
      if (type != "render3d" && type != "3d") continue;
      nlohmann::json summary = SceneStore::elementSummary(element);
      std::string geometryType = "box";
      int vertexCount = 0;
      int faceCount = 0;
      if (element.contains("data") && element["data"].is_object()) {
        const Mesh mesh = MeshForData(element["data"]);
        vertexCount = static_cast<int>(mesh.vertices.size());
        faceCount = static_cast<int>(mesh.faces.size());
        if (element["data"].contains("geometry") &&
            element["data"]["geometry"].is_object()) {
          geometryType =
              element["data"]["geometry"].value("type", std::string("box"));
        }
      }
      summary["geometryType"] = geometryType;
      summary["vertexCount"] = vertexCount;
      summary["faceCount"] = faceCount;
      elements.push_back(std::move(summary));
    }
    nlohmann::json result;
    result["elements"] = std::move(elements);
    result["count"] = static_cast<int>(result["elements"].size());
    return domainOk(result.dump());
  }
};

}  // namespace

WB_REGISTER_DOMAIN(Render3dDomain)

}  // namespace wb
