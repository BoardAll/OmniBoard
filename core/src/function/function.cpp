// function/function.cpp — domain "function" (task package 1.5).
// Owns: core/src/function.
//
// Ops (《渲染引擎设计》§8):
//   create   {pageId, element?}       -> function plot element
//   setStyle {elementId, style}       -> merge global style, or per-expression
//                                        style when style.expressionId is set
//   add      {elementId, expression}  -> {"expression":{..},"expressionCount"}
//   remove   {elementId, expressionId}-> {"expressionCount"}
//   analyze  {elementId, type}        -> zeros / extrema / derivative /
//                                        integral / area / symmetry / all
//   export   {elementId, format}      -> csv | json sampled points
//   list     {pageId}
//
// The expression engine is a recursive-descent parser producing a small AST
// (numbers, x, + - * / ^, parentheses, unary minus, implicit multiplication,
// constants pi/e, one- and two-argument functions: sin cos tan asin acos
// atan sinh cosh tanh ln log log10 log2 exp sqrt abs floor ceil round sign
// min max pow). A leading "y =" / "f(x) =" is accepted and stripped.
// Non-finite samples are dropped so plots break at poles instead of drawing
// across them.

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <memory>
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

// --- Expression engine ------------------------------------------------------

struct AstNode;
using Ast = std::shared_ptr<AstNode>;

struct AstNode {
  enum class Kind { Number, Variable, Unary, Binary, Function };
  Kind kind = Kind::Number;
  double value = 0.0;
  char op = 0;                 // Unary: '-' ; Binary: + - * / ^
  std::string name;            // Function name
  std::vector<Ast> children;
};

class Parser {
 public:
  explicit Parser(const std::string& text) : text_(text) {}

  /// Parses `text`; on success `ast` holds the tree, otherwise `error` the
  /// message (with the offending byte offset).
  bool Parse(Ast* ast, std::string* error) {
    SkipSpace();
    Ast root = ParseExpr();
    if (root == nullptr) {
      *error = error_.empty() ? "invalid expression" : error_;
      return false;
    }
    SkipSpace();
    if (pos_ < text_.size()) {
      *error = "unexpected token at offset " + std::to_string(pos_);
      return false;
    }
    *ast = root;
    return true;
  }

 private:
  bool Fail(const std::string& message) {
    if (error_.empty()) {
      error_ = message + " at offset " + std::to_string(pos_);
    }
    return false;
  }

  void SkipSpace() {
    while (pos_ < text_.size() &&
           (text_[pos_] == ' ' || text_[pos_] == '\t')) {
      ++pos_;
    }
  }

  char Peek() { return pos_ < text_.size() ? text_[pos_] : '\0'; }

  bool Consume(char expected) {
    SkipSpace();
    if (Peek() == expected) {
      ++pos_;
      return true;
    }
    return false;
  }

  // expr := term (('+'|'-') term)*
  Ast ParseExpr() {
    Ast left = ParseTerm();
    if (left == nullptr) return nullptr;
    for (;;) {
      SkipSpace();
      const char c = Peek();
      if (c != '+' && c != '-') break;
      ++pos_;
      Ast right = ParseTerm();
      if (right == nullptr) return nullptr;
      Ast node = std::make_shared<AstNode>();
      node->kind = AstNode::Kind::Binary;
      node->op = c;
      node->children = {left, right};
      left = node;
    }
    return left;
  }

  // term := unary (('*'|'/') unary | implicit-mul unary)*
  Ast ParseTerm() {
    Ast left = ParseUnary();
    if (left == nullptr) return nullptr;
    for (;;) {
      SkipSpace();
      const char c = Peek();
      if (c == '*' || c == '/') {
        ++pos_;
      } else if (c == '(' || c == '.' ||
                 (c >= '0' && c <= '9') ||
                 (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
        // Implicit multiplication: 2x, 3sin(x), (x+1)(x-1).
        // Note: cannot follow a plain number with '(' ambiguity, still fine.
      } else {
        break;
      }
      if (c == '*' || c == '/') {
        Ast right = ParseUnary();
        if (right == nullptr) return nullptr;
        Ast node = std::make_shared<AstNode>();
        node->kind = AstNode::Kind::Binary;
        node->op = c;
        node->children = {left, right};
        left = node;
      } else {
        Ast right = ParseUnary();
        if (right == nullptr) return nullptr;
        Ast node = std::make_shared<AstNode>();
        node->kind = AstNode::Kind::Binary;
        node->op = '*';
        node->children = {left, right};
        left = node;
      }
    }
    return left;
  }

  // unary := ('+'|'-') unary | power
  Ast ParseUnary() {
    SkipSpace();
    const char c = Peek();
    if (c == '+' || c == '-') {
      ++pos_;
      Ast inner = ParseUnary();
      if (inner == nullptr) return nullptr;
      if (c == '+') return inner;
      Ast node = std::make_shared<AstNode>();
      node->kind = AstNode::Kind::Unary;
      node->op = '-';
      node->children = {inner};
      return node;
    }
    return ParsePower();
  }

  // power := primary ('^' unary)?   (right-associative)
  Ast ParsePower() {
    Ast base = ParsePrimary();
    if (base == nullptr) return nullptr;
    SkipSpace();
    if (Peek() == '^') {
      ++pos_;
      Ast exponent = ParseUnary();
      if (exponent == nullptr) return nullptr;
      Ast node = std::make_shared<AstNode>();
      node->kind = AstNode::Kind::Binary;
      node->op = '^';
      node->children = {base, exponent};
      return node;
    }
    return base;
  }

  // primary := number | 'x' | constant | function '(' args ')' | '(' expr ')'
  Ast ParsePrimary() {
    SkipSpace();
    const char c = Peek();
    if (c == '(') {
      ++pos_;
      Ast inner = ParseExpr();
      if (inner == nullptr) return nullptr;
      if (!Consume(')')) {
        Fail("missing ')'");
        return nullptr;
      }
      return inner;
    }
    if ((c >= '0' && c <= '9') || c == '.') {
      const std::size_t start = pos_;
      while (pos_ < text_.size() &&
             ((text_[pos_] >= '0' && text_[pos_] <= '9') || text_[pos_] == '.')) {
        ++pos_;
      }
      const std::string number = text_.substr(start, pos_ - start);
      char* end = nullptr;
      const double value = std::strtod(number.c_str(), &end);
      if (end == number.c_str()) {
        Fail("invalid number");
        return nullptr;
      }
      Ast node = std::make_shared<AstNode>();
      node->kind = AstNode::Kind::Number;
      node->value = value;
      return node;
    }
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
      const std::size_t start = pos_;
      while (pos_ < text_.size() &&
             ((text_[pos_] >= 'a' && text_[pos_] <= 'z') ||
              (text_[pos_] >= 'A' && text_[pos_] <= 'Z') ||
              (text_[pos_] >= '0' && text_[pos_] <= '9') || text_[pos_] == '_')) {
        ++pos_;
      }
      std::string name = text_.substr(start, pos_ - start);
      std::string lower = name;
      for (char& ch : lower) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
      }
      if (lower == "x") {
        Ast node = std::make_shared<AstNode>();
        node->kind = AstNode::Kind::Variable;
        node->name = "x";
        return node;
      }
      if (lower == "pi" || lower == "e") {
        Ast node = std::make_shared<AstNode>();
        node->kind = AstNode::Kind::Number;
        node->value = lower == "pi" ? 3.14159265358979323846
                                    : 2.71828182845904523536;
        return node;
      }
      if (!Consume('(')) {
        Fail("unknown identifier '" + name + "'");
        return nullptr;
      }
      Ast node = std::make_shared<AstNode>();
      node->kind = AstNode::Kind::Function;
      node->name = lower;
      for (;;) {
        Ast argument = ParseExpr();
        if (argument == nullptr) return nullptr;
        node->children.push_back(argument);
        if (Consume(',')) continue;
        break;
      }
      if (!Consume(')')) {
        Fail("missing ')' after function arguments");
        return nullptr;
      }
      if (node->children.empty() || node->children.size() > 2) {
        Fail("function '" + name + "' takes one or two arguments");
        return nullptr;
      }
      return node;
    }
    Fail("unexpected token");
    return nullptr;
  }

  const std::string& text_;
  std::size_t pos_ = 0;
  std::string error_;
};

double EvalNode(const Ast& node, double x) {
  switch (node->kind) {
    case AstNode::Kind::Number:
      return node->value;
    case AstNode::Kind::Variable:
      return x;
    case AstNode::Kind::Unary:
      return -EvalNode(node->children[0], x);
    case AstNode::Kind::Binary: {
      const double a = EvalNode(node->children[0], x);
      const double b = EvalNode(node->children[1], x);
      switch (node->op) {
        case '+': return a + b;
        case '-': return a - b;
        case '*': return a * b;
        case '/': return a / b;
        case '^': return std::pow(a, b);
        default: return std::nan("");
      }
    }
    case AstNode::Kind::Function: {
      const double a = EvalNode(node->children[0], x);
      const std::string& f = node->name;
      if (f == "sin") return std::sin(a);
      if (f == "cos") return std::cos(a);
      if (f == "tan") return std::tan(a);
      if (f == "asin") return std::asin(a);
      if (f == "acos") return std::acos(a);
      if (f == "atan") return std::atan(a);
      if (f == "sinh") return std::sinh(a);
      if (f == "cosh") return std::cosh(a);
      if (f == "tanh") return std::tanh(a);
      if (f == "ln") return std::log(a);
      if (f == "log" || f == "log10") return std::log10(a);
      if (f == "log2") return std::log2(a);
      if (f == "exp") return std::exp(a);
      if (f == "sqrt") return std::sqrt(a);
      if (f == "abs") return std::fabs(a);
      if (f == "floor") return std::floor(a);
      if (f == "ceil") return std::ceil(a);
      if (f == "round") return std::round(a);
      if (f == "sign") return (a > 0) - (a < 0);
      if (node->children.size() == 2) {
        const double b = EvalNode(node->children[1], x);
        if (f == "min") return std::min(a, b);
        if (f == "max") return std::max(a, b);
        if (f == "pow") return std::pow(a, b);
      }
      return std::nan("");
    }
  }
  return std::nan("");
}

/// Strips a leading "y =", "f(x) =", "r =" etc.; returns the parsed AST.
bool ParseExpression(const std::string& raw, Ast* ast, std::string* error) {
  std::string text = raw;
  const std::size_t equals = text.find('=');
  if (equals != std::string::npos) text = text.substr(equals + 1);
  Parser parser(text);
  return parser.Parse(ast, error);
}

struct SamplePoint {
  double x = 0.0;
  double y = 0.0;
};

struct Viewport {
  double xMin = -10.0;
  double xMax = 10.0;
  double yMin = -10.0;
  double yMax = 10.0;
};

Viewport ReadViewport(const nlohmann::json& data) {
  Viewport viewport;
  if (data.contains("viewport") && data["viewport"].is_object()) {
    const nlohmann::json& v = data["viewport"];
    viewport.xMin = v.value("xMin", viewport.xMin);
    viewport.xMax = v.value("xMax", viewport.xMax);
    viewport.yMin = v.value("yMin", viewport.yMin);
    viewport.yMax = v.value("yMax", viewport.yMax);
  }
  if (viewport.xMax <= viewport.xMin) viewport.xMax = viewport.xMin + 1.0;
  return viewport;
}

/// Samples a parsed expression; non-finite values are dropped.
std::vector<SamplePoint> Sample(const Ast& ast, const Viewport& viewport,
                                int count) {
  std::vector<SamplePoint> points;
  count = std::max(2, std::min(count, 100000));
  const double step = (viewport.xMax - viewport.xMin) / (count - 1);
  points.reserve(static_cast<std::size_t>(count));
  for (int i = 0; i < count; ++i) {
    const double x = viewport.xMin + step * i;
    double y = EvalNode(ast, x);
    if (!std::isfinite(y)) continue;
    // Clamp absurd magnitudes so JSON stays sane near poles.
    if (y > 1e12) y = 1e12;
    if (y < -1e12) y = -1e12;
    points.push_back(SamplePoint{x, y});
  }
  return points;
}

/// Finds x in [a,b] where f crosses zero (sign change), bisection refine.
double BisectZero(const Ast& ast, double a, double b, double fa) {
  for (int i = 0; i < 80; ++i) {
    const double mid = 0.5 * (a + b);
    const double fm = EvalNode(ast, mid);
    if (!std::isfinite(fm)) return mid;
    if ((fa < 0) == (fm < 0)) {
      a = mid;
      fa = fm;
    } else {
      b = mid;
    }
  }
  return 0.5 * (a + b);
}

class FunctionDomain : public DomainHandler {
 public:
  std::string name() const override { return "function"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "create") return Create(args);
    if (op == "setStyle") return SetStyle(args);
    if (op == "add") return Add(args);
    if (op == "remove") return Remove(args);
    if (op == "analyze") return Analyze(args);
    if (op == "export") return Export(args);
    if (op == "list") return List(args);
    return domainError("NotFound", "unknown function op: " + op);
  }

 private:
  // --- element lookup -------------------------------------------------------
  /// Finds a "function" element; fills errorCode/errorMessage on failure.
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
    if (element.value("type", std::string()) != "function") {
      *errorCode = "InvalidArgument";
      *errorMessage = "element is not a function plot: " + elementId;
      return nullptr;
    }
    return &element;
  }

  static nlohmann::json DefaultData() {
    nlohmann::json data;
    data["expressions"] = nlohmann::json::array();
    nlohmann::json viewport;
    viewport["xMin"] = -10.0;
    viewport["xMax"] = 10.0;
    viewport["yMin"] = -10.0;
    viewport["yMax"] = 10.0;
    data["viewport"] = std::move(viewport);
    data["samples"] = 256;
    nlohmann::json grid;
    grid["show"] = true;
    grid["step"] = 1.0;
    data["grid"] = std::move(grid);
    return data;
  }

  static const char* PaletteColor(std::size_t index) {
    static const char* kPalette[] = {"#3370FF", "#FF6B9D", "#22C55E",
                                     "#F59E0B", "#8B5CF6", "#06B6D4"};
    return kPalette[index % (sizeof(kPalette) / sizeof(kPalette[0]))];
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
    element["type"] = "function";

    nlohmann::json data = DefaultData();
    if (element.contains("data") && element["data"].is_object()) {
      for (auto it = element["data"].begin(); it != element["data"].end(); ++it) {
        data[it.key()] = it.value();
      }
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

    nlohmann::json& created =
        page->elements[static_cast<std::size_t>(index)];
    // Optional convenience: seed the first expression.
    if (args.contains("args") && args["args"].is_object()) {
      // reserved
    }
    nlohmann::json result;
    result["element"] = created;
    result["elementId"] = elementId;
    result["pageId"] = pageId;
    result["type"] = "function";
    return domainOk(result.dump());
  }

  std::string SetStyle(const nlohmann::json& args) {
    const std::string elementId = args.value("elementId", std::string());
    if (!args.contains("style") || !args["style"].is_object()) {
      return domainError("InvalidArgument", "args.style is required");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json style = args["style"];
    const std::string targetId = style.value("expressionId", std::string());
    if (!targetId.empty()) {
      style.erase("expressionId");
      nlohmann::json& expressions = (*element)["data"]["expressions"];
      bool found = false;
      for (nlohmann::json& expression : expressions) {
        if (expression.value("id", std::string()) == targetId) {
          for (auto it = style.begin(); it != style.end(); ++it) {
            expression[it.key()] = it.value();
          }
          found = true;
          break;
        }
      }
      if (!found) {
        return domainError("NotFound", "unknown expression: " + targetId);
      }
    } else {
      nlohmann::json merged =
          element->value("style", nlohmann::json::object());
      if (!merged.is_object()) merged = nlohmann::json::object();
      for (auto it = style.begin(); it != style.end(); ++it) {
        merged[it.key()] = it.value();
      }
      (*element)["style"] = std::move(merged);
    }
    (*element)["updatedAt"] = timeMillis();
    nlohmann::json result;
    result["element"] = *element;
    result["elementId"] = elementId;
    return domainOk(result.dump());
  }

  std::string Add(const nlohmann::json& args) {
    const std::string elementId = args.value("elementId", std::string());
    std::string expression =
        args.value("expression", std::string());
    if (expression.empty()) {
      return domainError("InvalidArgument", "args.expression is required");
    }
    Ast ast;
    std::string parseError;
    if (!ParseExpression(expression, &ast, &parseError)) {
      return domainError("InvalidArgument", "无法解析表达式: " + parseError);
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& expressions = (*element)["data"]["expressions"];
    if (!expressions.is_array()) expressions = nlohmann::json::array();
    int nextIndex = 1;
    for (const auto& item : expressions) {
      const std::string id = item.value("id", std::string("expr-"));
      if (id.rfind("expr-", 0) == 0) {
        nextIndex = std::max(nextIndex,
                             std::atoi(id.c_str() + 5) + 1);
      }
    }
    nlohmann::json entry;
    entry["id"] = "expr-" + std::to_string(nextIndex);
    entry["expression"] = expression;
    entry["color"] = PaletteColor(expressions.size());
    entry["width"] = 2;
    entry["lineStyle"] = "solid";
    entry["visible"] = true;
    expressions.push_back(std::move(entry));
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["expression"] = expressions.back();
    result["expressionCount"] = static_cast<int>(expressions.size());
    result["elementId"] = elementId;
    return domainOk(result.dump());
  }

  std::string Remove(const nlohmann::json& args) {
    const std::string elementId = args.value("elementId", std::string());
    const std::string expressionId =
        args.value("expressionId", std::string());
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& expressions = (*element)["data"]["expressions"];
    const std::size_t before = expressions.size();
    expressions.erase(
        std::remove_if(expressions.begin(), expressions.end(),
                       [&expressionId](const nlohmann::json& item) {
                         return item.value("id", std::string()) == expressionId;
                       }),
        expressions.end());
    if (expressions.size() == before) {
      return domainError("NotFound", "unknown expression: " + expressionId);
    }
    (*element)["updatedAt"] = timeMillis();
    nlohmann::json result;
    result["elementId"] = elementId;
    result["expressionCount"] = static_cast<int>(expressions.size());
    return domainOk(result.dump());
  }

  std::string Analyze(const nlohmann::json& args) {
    const std::string elementId = args.value("elementId", std::string());
    const std::string type = args.value("type", std::string("all"));
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    const nlohmann::json& expressions = (*element)["data"]["expressions"];
    const nlohmann::json* first = nullptr;
    for (const auto& expression : expressions) {
      if (expression.value("visible", true)) {
        first = &expression;
        break;
      }
    }
    if (first == nullptr) {
      return domainError("InvalidArgument", "no expression to analyze");
    }
    Ast ast;
    std::string parseError;
    if (!ParseExpression(first->value("expression", std::string()), &ast,
                         &parseError)) {
      return domainError("InvalidArgument", "无法解析表达式: " + parseError);
    }
    const Viewport viewport = ReadViewport((*element)["data"]);
    const int samples = (*element)["data"].value("samples", 256);
    const std::vector<SamplePoint> points = Sample(ast, viewport, samples);

    const bool wantAll = type == "all";
    nlohmann::json analysis;
    analysis["expression"] = first->value("expression", std::string());
    analysis["type"] = type;
    if (wantAll || type == "zeros") {
      analysis["zeros"] = Zeros(ast, points);
    }
    if (wantAll || type == "extrema") {
      analysis["extrema"] = Extrema(ast, points, viewport);
    }
    if (wantAll || type == "derivative") {
      analysis["derivative"] = Derivative(ast, viewport, samples);
    }
    if (wantAll || type == "integral") {
      analysis["integral"] = Integral(points);
    }
    if (wantAll || type == "area") {
      analysis["area"] = Integral(points, true);
    }
    if (wantAll || type == "symmetry") {
      analysis["symmetry"] = Symmetry(ast, viewport);
    }
    if (!wantAll && type != "zeros" && type != "extrema" &&
        type != "derivative" && type != "integral" && type != "area" &&
        type != "symmetry") {
      return domainError("InvalidArgument", "unknown analysis type: " + type);
    }
    return domainOk(nlohmann::json{{"analysis", std::move(analysis)}}.dump());
  }

  std::string Export(const nlohmann::json& args) {
    const std::string elementId = args.value("elementId", std::string());
    const std::string format = args.value("format", std::string("json"));
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element =
        Find(SceneStore::instance(), elementId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    const nlohmann::json& expressions = (*element)["data"]["expressions"];
    const nlohmann::json* first = nullptr;
    for (const auto& expression : expressions) {
      if (expression.value("visible", true)) {
        first = &expression;
        break;
      }
    }
    if (first == nullptr) {
      return domainError("InvalidArgument", "no expression to export");
    }
    Ast ast;
    std::string parseError;
    if (!ParseExpression(first->value("expression", std::string()), &ast,
                         &parseError)) {
      return domainError("InvalidArgument", "无法解析表达式: " + parseError);
    }
    const Viewport viewport = ReadViewport((*element)["data"]);
    const std::vector<SamplePoint> points =
        Sample(ast, viewport, (*element)["data"].value("samples", 256));

    nlohmann::json result;
    result["elementId"] = elementId;
    result["expression"] = first->value("expression", std::string());
    result["count"] = static_cast<int>(points.size());
    if (format == "csv") {
      std::string csv = "x,y\n";
      for (const SamplePoint& point : points) {
        csv += std::to_string(point.x) + "," + std::to_string(point.y) + "\n";
      }
      result["format"] = "csv";
      result["csv"] = std::move(csv);
    } else if (format == "json" || format == "points") {
      nlohmann::json list = nlohmann::json::array();
      for (const SamplePoint& point : points) {
        nlohmann::json item;
        item["x"] = point.x;
        item["y"] = point.y;
        list.push_back(std::move(item));
      }
      result["format"] = "json";
      result["points"] = std::move(list);
    } else {
      return domainError("InvalidArgument", "unknown export format: " + format);
    }
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
      if (element.value("type", std::string()) != "function") continue;
      nlohmann::json summary = SceneStore::elementSummary(element);
      int expressionCount = 0;
      if (element.contains("data") && element["data"].is_object() &&
          element["data"].contains("expressions") &&
          element["data"]["expressions"].is_array()) {
        expressionCount =
            static_cast<int>(element["data"]["expressions"].size());
      }
      summary["expressionCount"] = expressionCount;
      elements.push_back(std::move(summary));
    }
    nlohmann::json result;
    result["elements"] = std::move(elements);
    result["count"] = static_cast<int>(result["elements"].size());
    return domainOk(result.dump());
  }

  // --- analysis helpers -----------------------------------------------------
  static nlohmann::json Zeros(const Ast& ast,
                              const std::vector<SamplePoint>& points) {
    nlohmann::json zeros = nlohmann::json::array();
    for (std::size_t i = 0; i + 1 < points.size(); ++i) {
      const SamplePoint& a = points[i];
      const SamplePoint& b = points[i + 1];
      double root = 0.0;
      bool found = false;
      if (a.y == 0.0) {
        root = a.x;
        found = true;
      } else if ((a.y < 0) != (b.y < 0)) {
        root = BisectZero(ast, a.x, b.x, a.y);
        found = true;
      }
      if (!found) continue;
      if (!zeros.empty() &&
          std::fabs(zeros.back().get<double>() - root) < 1e-7) {
        continue;
      }
      zeros.push_back(root);
      if (zeros.size() >= 100) break;
    }
    return zeros;
  }

  static nlohmann::json Extrema(const Ast& ast,
                                const std::vector<SamplePoint>& points,
                                const Viewport& viewport) {
    nlohmann::json extrema = nlohmann::json::array();
    const double h = (viewport.xMax - viewport.xMin) /
                     std::max(2.0, static_cast<double>(points.size() - 1));
    for (std::size_t i = 1; i + 1 < points.size(); ++i) {
      const double previous = points[i - 1].y;
      const double current = points[i].y;
      const double next = points[i + 1].y;
      const bool isMax = previous < current && current > next;
      const bool isMin = previous > current && current < next;
      if (!isMax && !isMin) continue;
      // Quadratic vertex through the three samples.
      const double denom = previous - 2.0 * current + next;
      double x = points[i].x;
      if (std::fabs(denom) > 1e-12) {
        x = points[i].x + 0.5 * h * (previous - next) / denom;
      }
      const double y = EvalNode(ast, x);
      nlohmann::json item;
      item["type"] = isMax ? "max" : "min";
      item["x"] = x;
      item["y"] = std::isfinite(y) ? y : current;
      extrema.push_back(std::move(item));
      if (extrema.size() >= 100) break;
    }
    return extrema;
  }

  static nlohmann::json Derivative(const Ast& ast, const Viewport& viewport,
                                   int samples) {
    nlohmann::json points = nlohmann::json::array();
    const int count = std::max(2, std::min(samples, 4096));
    const double step = (viewport.xMax - viewport.xMin) / (count - 1);
    const double h = std::max(1e-7, step / 2.0);
    for (int i = 0; i < count; ++i) {
      const double x = viewport.xMin + step * i;
      const double d =
          (EvalNode(ast, x + h) - EvalNode(ast, x - h)) / (2.0 * h);
      if (!std::isfinite(d)) continue;
      nlohmann::json item;
      item["x"] = x;
      item["d"] = d;
      points.push_back(std::move(item));
    }
    nlohmann::json result;
    result["points"] = std::move(points);
    result["count"] = static_cast<int>(result["points"].size());
    return result;
  }

  static double Integral(const std::vector<SamplePoint>& points,
                         bool absolute = false) {
    double total = 0.0;
    for (std::size_t i = 0; i + 1 < points.size(); ++i) {
      const double y0 = absolute ? std::fabs(points[i].y) : points[i].y;
      const double y1 = absolute ? std::fabs(points[i + 1].y) : points[i + 1].y;
      total += 0.5 * (y0 + y1) * (points[i + 1].x - points[i].x);
    }
    return total;
  }

  static nlohmann::json Symmetry(const Ast& ast, const Viewport& viewport) {
    const double lo = std::max(viewport.xMin, -viewport.xMax);
    const double hi = std::min(viewport.xMax, -viewport.xMin);
    if (hi <= lo) return nlohmann::json("none");
    double maxAbs = 0.0;
    std::vector<std::pair<double, double>> values;  // (f(x), f(-x))
    const int count = 64;
    for (int i = 0; i < count; ++i) {
      const double x = lo + (hi - lo) * i / (count - 1);
      const double fx = EvalNode(ast, x);
      const double fnx = EvalNode(ast, -x);
      if (!std::isfinite(fx) || !std::isfinite(fnx)) continue;
      maxAbs = std::max(maxAbs, std::max(std::fabs(fx), std::fabs(fnx)));
      values.emplace_back(fx, fnx);
    }
    if (values.empty()) return nlohmann::json("none");
    const double tolerance = std::max(1e-6, 1e-4 * maxAbs);
    bool even = true;
    bool odd = true;
    for (const auto& [fx, fnx] : values) {
      if (std::fabs(fx - fnx) > tolerance) even = false;
      if (std::fabs(fx + fnx) > tolerance) odd = false;
    }
    if (even && odd) return nlohmann::json("both");  // f == 0
    if (even) return nlohmann::json("even");
    if (odd) return nlohmann::json("odd");
    return nlohmann::json("none");
  }
};

}  // namespace

WB_REGISTER_DOMAIN(FunctionDomain)

}  // namespace wb
