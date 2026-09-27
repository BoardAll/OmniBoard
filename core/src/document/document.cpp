// document/document.cpp — domain "document" (task package 1.6).
// Owns: core/src/document.
//
// Ops (《渲染引擎设计》§10): import, info, setPage, list.
//
// Document (PDF) support is a headless stub backend in Wave 1: `import`
// registers the element with its source, title, page count and a page
// table (A4 595x842pt by default); page rasterization itself is done by
// the platform layer (PDFium / MuPDF) in a later wave, exactly like the
// bgfx render jobs of the "render3d" domain. PPT files are not embedded
// (§10.2) and are flagged openWithSystem instead.

#include <algorithm>
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
    if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
  }
  return text;
}

/// Picks the element id from args: `documentId` first, then `elementId`.
std::string ElementIdArg(const nlohmann::json& args) {
  const std::string documentId = args.value("documentId", std::string());
  if (!documentId.empty()) return documentId;
  return args.value("elementId", std::string());
}

/// Basename without extension, used as the default title.
std::string BaseName(const std::string& source) {
  std::size_t end = source.size();
  const std::size_t slash = source.find_last_of("/\\");
  std::size_t start = slash == std::string::npos ? 0 : slash + 1;
  const std::size_t dot = source.find_last_of('.');
  if (dot != std::string::npos && dot > start) end = dot;
  if (end <= start) return std::string();
  return source.substr(start, end - start);
}

bool EndsWithPpt(const std::string& source) {
  const std::string lower = ToLower(source);
  const auto ends = [&lower](const char* suffix) {
    const std::size_t length = std::char_traits<char>::length(suffix);
    return lower.size() >= length &&
           lower.compare(lower.size() - length, length, suffix) == 0;
  };
  return ends(".ppt") || ends(".pptx");
}

}  // namespace

class DocumentDomain : public DomainHandler {
 public:
  std::string name() const override { return "document"; }

  std::string handle(const std::string& op,
                     const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "import" || op == "open") return Import(args);
    if (op == "info") return Info(args);
    if (op == "setPage" || op == "set_page" || op == "goToPage") {
      return SetPage(args);
    }
    if (op == "list") return List(args);
    return domainError("NotFound", "unknown document op: " + op);
  }

 private:
  /// Finds a "document" element; fills errorCode/errorMessage on failure.
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
    if (element.value("type", std::string()) != "document") {
      *errorCode = "InvalidArgument";
      *errorMessage = "element is not a document: " + elementId;
      return nullptr;
    }
    return &element;
  }

  static nlohmann::json BuildPages(int pageCount, double width,
                                   double height) {
    nlohmann::json pages = nlohmann::json::array();
    for (int i = 1; i <= pageCount; ++i) {
      nlohmann::json page;
      page["index"] = i;
      page["width"] = width;
      page["height"] = height;
      page["rendered"] = false;
      pages.push_back(std::move(page));
    }
    return pages;
  }

  // --- ops ------------------------------------------------------------------
  std::string Import(const nlohmann::json& args) {
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
    element["type"] = "document";

    const std::string source = args.value("source", std::string());
    int pageCount = args.value("pageCount", 1);
    if (pageCount < 1) {
      return domainError("InvalidArgument", "pageCount must be >= 1");
    }
    double pageWidth = 595.0;
    double pageHeight = 842.0;
    if (args.contains("pageSize") && args["pageSize"].is_object()) {
      pageWidth = args["pageSize"].value("width", pageWidth);
      pageHeight = args["pageSize"].value("height", pageHeight);
    }
    if (pageWidth <= 0.0 || pageHeight <= 0.0) {
      return domainError("InvalidArgument", "pageSize must be positive");
    }
    std::string title = args.value("title", std::string());
    if (title.empty()) title = BaseName(source);
    if (title.empty()) title = "未命名文档";

    nlohmann::json data;
    data["source"] = source;
    data["title"] = title;
    data["pageCount"] = pageCount;
    data["currentPage"] = 1;
    data["backend"] = "stub";
    data["openWithSystem"] = EndsWithPpt(source);
    data["pages"] = BuildPages(pageCount, pageWidth, pageHeight);
    if (element.contains("data") && element["data"].is_object()) {
      for (auto it = element["data"].begin(); it != element["data"].end();
           ++it) {
        data[it.key()] = it.value();
      }
    }
    // User-provided data may override the table size; regenerate the page
    // list so it always matches pageCount.
    pageCount = data.value("pageCount", pageCount);
    if (pageCount < 1) {
      return domainError("InvalidArgument", "pageCount must be >= 1");
    }
    data["pages"] = BuildPages(pageCount, pageWidth, pageHeight);
    if (!data.contains("currentPage") || !data["currentPage"].is_number_integer()) {
      data["currentPage"] = 1;
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
    nlohmann::json result;
    result["element"] = created;
    result["elementId"] = elementId;
    result["pageId"] = pageId;
    result["type"] = "document";
    result["title"] = created["data"].value("title", std::string());
    result["pageCount"] = created["data"].value("pageCount", 1);
    result["currentPage"] = created["data"].value("currentPage", 1);
    result["backend"] = created["data"].value("backend", std::string("stub"));
    return domainOk(result.dump());
  }

  std::string Info(const nlohmann::json& args) {
    const std::string elementId = ElementIdArg(args);
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    const nlohmann::json& data = (*element)["data"];
    nlohmann::json result;
    result["elementId"] = elementId;
    result["title"] = data.value("title", std::string());
    result["source"] = data.value("source", std::string());
    result["pageCount"] = data.value("pageCount", 1);
    result["currentPage"] = data.value("currentPage", 1);
    result["backend"] = data.value("backend", std::string("stub"));
    result["openWithSystem"] = data.value("openWithSystem", false);
    result["pages"] = data.value("pages", nlohmann::json::array());
    return domainOk(result.dump());
  }

  std::string SetPage(const nlohmann::json& args) {
    const std::string elementId = ElementIdArg(args);
    if (!args.contains("page") || !args["page"].is_number_integer()) {
      return domainError("InvalidArgument", "args.page is required");
    }
    const int page = args["page"].get<int>();
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& data = (*element)["data"];
    const int pageCount = data.value("pageCount", 1);
    if (page < 1 || page > pageCount) {
      return domainError("InvalidArgument",
                         "page out of range: " + std::to_string(page));
    }
    data["currentPage"] = page;
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["elementId"] = elementId;
    result["currentPage"] = page;
    result["pageCount"] = pageCount;
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
      if (element.value("type", std::string()) != "document") continue;
      nlohmann::json summary = SceneStore::elementSummary(element);
      std::string title;
      int pageCount = 0;
      int currentPage = 0;
      if (element.contains("data") && element["data"].is_object()) {
        title = element["data"].value("title", std::string());
        pageCount = element["data"].value("pageCount", 0);
        currentPage = element["data"].value("currentPage", 0);
      }
      summary["title"] = title;
      summary["pageCount"] = pageCount;
      summary["currentPage"] = currentPage;
      elements.push_back(std::move(summary));
    }
    nlohmann::json result;
    result["elements"] = std::move(elements);
    result["count"] = static_cast<int>(result["elements"].size());
    return domainOk(result.dump());
  }
};

WB_REGISTER_DOMAIN(DocumentDomain)

}  // namespace wb
