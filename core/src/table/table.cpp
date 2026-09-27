// table/table.cpp — domain "table" (task package 1.5).
// Owns: core/src/table.
//
// Ops (《AI/MCP》§7 / 《MCP_Server》§11): create, setCell(set_cell),
// getCell(get_cell), setFormula(set_formula), sort, filter,
// setStyle(set_style), list.
//
// Data model:
//   data.rows / data.cols / data.cells   { "A1": {"value":..,"formula":"=.."} }
//   data.cellStyles                      { "A1:B2": {..} }
// Addresses are A1-style (1-based row). Formula engine supports + - * / ^,
// parentheses, comparisons, string literals, cell refs, ranges A1:B2 and the
// functions SUM AVG/AVERAGE MIN MAX COUNT COUNTA IF ROUND ABS SQRT.
// Cycles surface as "#CYCLE!" errors; every mutation re-evaluates the sheet.

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <functional>
#include <map>
#include <set>
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

// --- addresses ---------------------------------------------------------------

std::string ToUpper(std::string value) {
  for (char& ch : value) {
    ch = static_cast<char>(std::toupper(static_cast<unsigned char>(ch)));
  }
  return value;
}

/// "b12" -> col=1, row=12; false when malformed.
bool ParseAddress(const std::string& raw, int* column, int* row) {
  std::string address = ToUpper(raw);
  std::size_t i = 0;
  int col = 0;
  while (i < address.size() && address[i] >= 'A' && address[i] <= 'Z') {
    col = col * 26 + (address[i] - 'A' + 1);
    ++i;
  }
  if (i == 0 || i >= address.size()) return false;
  long long number = 0;
  for (; i < address.size(); ++i) {
    if (address[i] < '0' || address[i] > '9') return false;
    number = number * 10 + (address[i] - '0');
    if (number > 1000000) return false;
  }
  if (number < 1) return false;
  *column = col - 1;
  *row = static_cast<int>(number);
  return true;
}

std::string MakeAddress(int column, int row) {
  std::string letters;
  int value = column + 1;
  while (value > 0) {
    const int remainder = (value - 1) % 26;
    letters.insert(letters.begin(), static_cast<char>('A' + remainder));
    value = (value - 1) / 26;
  }
  return letters + std::to_string(row);
}

// --- formula values ----------------------------------------------------------

struct Value {
  enum class Kind { Number, Text, Bool, List, Error, Empty };
  Kind kind = Kind::Empty;
  double number = 0.0;
  std::string text;
  bool boolean = false;
  std::vector<std::string> cells;  // List: range addresses
  std::string error;

  static Value Num(double v) {
    Value value;
    value.kind = Kind::Number;
    value.number = v;
    return value;
  }
  static Value Str(const std::string& v) {
    Value value;
    value.kind = Kind::Text;
    value.text = v;
    return value;
  }
  static Value Err(const std::string& code) {
    Value value;
    value.kind = Kind::Error;
    value.error = code;
    return value;
  }
};

bool IsBlank(const Value& value) {
  return value.kind == Value::Kind::Empty ||
         (value.kind == Value::Kind::Text && value.text.empty());
}

bool Truthy(const Value& value) {
  switch (value.kind) {
    case Value::Kind::Number: return value.number != 0.0;
    case Value::Kind::Bool: return value.boolean;
    case Value::Kind::Text: return !value.text.empty();
    case Value::Kind::List: return !value.cells.empty();
    default: return false;
  }
}

/// Numeric coercion for arithmetic; text that parses as a number is accepted.
Value CoerceNumber(const Value& value) {
  if (value.kind == Value::Kind::Number) return value;
  if (value.kind == Value::Kind::Bool) return Value::Num(value.boolean ? 1 : 0);
  if (value.kind == Value::Kind::Text) {
    if (value.text.empty()) return Value::Num(0);
    char* end = nullptr;
    const double number = std::strtod(value.text.c_str(), &end);
    if (end != nullptr && *end == '\0') return Value::Num(number);
    return Value::Err("#VALUE!");
  }
  if (value.kind == Value::Kind::Empty) return Value::Num(0);
  if (value.kind == Value::Kind::Error) return value;
  return Value::Err("#VALUE!");
}

/// Evaluation context shared across one sheet pass.
struct EvalContext {
  const nlohmann::json* cells = nullptr;
  std::map<std::string, Value>* memo = nullptr;
  std::set<std::string>* visiting = nullptr;
};

class Evaluator {
 public:
  Evaluator(const std::string& formula, EvalContext* context)
      : text_(formula), context_(context) {}

  Value Evaluate() {
    pos_ = 0;
    Skip();
    Value value = ParseComparison(true);
    if (value.kind == Value::Kind::Error) return value;
    Skip();
    if (pos_ < text_.size()) return Value::Err("#SYNTAX");
    return value;
  }

 private:
  void Skip() {
    while (pos_ < text_.size() && (text_[pos_] == ' ' || text_[pos_] == '\t')) {
      ++pos_;
    }
  }

  char Peek() { return pos_ < text_.size() ? text_[pos_] : '\0'; }

  bool Consume(char expected) {
    Skip();
    if (Peek() == expected) {
      ++pos_;
      return true;
    }
    return false;
  }

  bool Consume2(const char* pair) {
    Skip();
    if (pos_ + 1 < text_.size() && text_[pos_] == pair[0] &&
        text_[pos_ + 1] == pair[1]) {
      pos_ += 2;
      return true;
    }
    return false;
  }

  // comparison := additive (('='|'<>'|'<='|'>='|'<'|'>') additive)?
  Value ParseComparison(bool evaluate) {
    Value left = ParseAdditive(evaluate);
    if (left.kind == Value::Kind::Error) return left;
    Skip();
    std::string op;
    if (Consume2("<>")) op = "<>";
    else if (Consume2("<=")) op = "<=";
    else if (Consume2(">=")) op = ">=";
    else if (Consume('=')) op = "=";
    else if (Consume('<')) op = "<";
    else if (Consume('>')) op = ">";
    if (op.empty()) return left;
    Value right = ParseAdditive(evaluate);
    if (right.kind == Value::Kind::Error) return right;
    if (!evaluate) return Value::Num(0);
    bool result = false;
    const Value a = CoerceNumber(left);
    const Value b = CoerceNumber(right);
    if (a.kind == Value::Kind::Number && b.kind == Value::Kind::Number) {
      const double x = a.number;
      const double y = b.number;
      if (op == "=") result = x == y;
      else if (op == "<>") result = x != y;
      else if (op == "<") result = x < y;
      else if (op == ">") result = x > y;
      else if (op == "<=") result = x <= y;
      else result = x >= y;
    } else {
      const std::string x = left.kind == Value::Kind::Text ? left.text
                                                           : std::string();
      const std::string y = right.kind == Value::Kind::Text ? right.text
                                                            : std::string();
      if (op == "=") result = x == y;
      else if (op == "<>") result = x != y;
      else return Value::Err("#VALUE!");
    }
    Value value;
    value.kind = Value::Kind::Bool;
    value.boolean = result;
    return value;
  }

  Value ParseAdditive(bool evaluate) {
    Value left = ParseTerm(evaluate);
    if (left.kind == Value::Kind::Error) return left;
    for (;;) {
      Skip();
      const char c = Peek();
      if (c != '+' && c != '-') return left;
      ++pos_;
      Value right = ParseTerm(evaluate);
      if (right.kind == Value::Kind::Error) return right;
      if (!evaluate) continue;
      const Value a = CoerceNumber(left);
      const Value b = CoerceNumber(right);
      if (a.kind == Value::Kind::Error) return a;
      if (b.kind == Value::Kind::Error) return b;
      left = Value::Num(c == '+' ? a.number + b.number : a.number - b.number);
    }
  }

  Value ParseTerm(bool evaluate) {
    Value left = ParsePower(evaluate);
    if (left.kind == Value::Kind::Error) return left;
    for (;;) {
      Skip();
      const char c = Peek();
      if (c != '*' && c != '/') return left;
      ++pos_;
      Value right = ParsePower(evaluate);
      if (right.kind == Value::Kind::Error) return right;
      if (!evaluate) continue;
      const Value a = CoerceNumber(left);
      const Value b = CoerceNumber(right);
      if (a.kind == Value::Kind::Error) return a;
      if (b.kind == Value::Kind::Error) return b;
      if (c == '/') {
        if (b.number == 0.0) return Value::Err("#DIV/0!");
        left = Value::Num(a.number / b.number);
      } else {
        left = Value::Num(a.number * b.number);
      }
    }
  }

  Value ParsePower(bool evaluate) {
    Value base = ParseUnary(evaluate);
    if (base.kind == Value::Kind::Error) return base;
    Skip();
    if (Peek() == '^') {
      ++pos_;
      Value exponent = ParsePower(evaluate);  // right-associative
      if (exponent.kind == Value::Kind::Error) return exponent;
      if (!evaluate) return Value::Num(0);
      const Value a = CoerceNumber(base);
      const Value b = CoerceNumber(exponent);
      if (a.kind == Value::Kind::Error) return a;
      if (b.kind == Value::Kind::Error) return b;
      return Value::Num(std::pow(a.number, b.number));
    }
    return base;
  }

  Value ParseUnary(bool evaluate) {
    Skip();
    const char c = Peek();
    if (c == '-' || c == '+') {
      ++pos_;
      Value inner = ParseUnary(evaluate);
      if (inner.kind == Value::Kind::Error) return inner;
      if (!evaluate || c == '+') return inner;
      const Value a = CoerceNumber(inner);
      if (a.kind == Value::Kind::Error) return a;
      return Value::Num(-a.number);
    }
    return ParsePrimary(evaluate);
  }

  Value ParsePrimary(bool evaluate) {
    Skip();
    const char c = Peek();
    if (c == '(') {
      ++pos_;
      Value inner = ParseComparison(evaluate);
      if (inner.kind == Value::Kind::Error) return inner;
      if (!Consume(')')) return Value::Err("#SYNTAX");
      return inner;
    }
    if ((c >= '0' && c <= '9') || c == '.') {
      const std::size_t start = pos_;
      while (pos_ < text_.size() &&
             ((text_[pos_] >= '0' && text_[pos_] <= '9') ||
              text_[pos_] == '.')) {
        ++pos_;
      }
      if (!evaluate) return Value::Num(0);
      return Value::Num(
          std::strtod(text_.substr(start, pos_ - start).c_str(), nullptr));
    }
    if (c == '"') {
      ++pos_;
      std::string value;
      while (pos_ < text_.size() && text_[pos_] != '"') {
        if (text_[pos_] == '\\' && pos_ + 1 < text_.size()) ++pos_;
        value.push_back(text_[pos_]);
        ++pos_;
      }
      if (!Consume('"')) return Value::Err("#SYNTAX");
      return evaluate ? Value::Str(value) : Value::Str(std::string());
    }
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) {
      const std::size_t start = pos_;
      while (pos_ < text_.size() &&
             (std::isalnum(static_cast<unsigned char>(text_[pos_])) ||
              text_[pos_] == '_')) {
        ++pos_;
      }
      const std::string name = text_.substr(start, pos_ - start);
      Skip();
      if (Peek() == '(') {
        return ParseFunction(ToUpper(name), evaluate);
      }
      // Cell reference (optionally a range A1:B2).
      int column = 0;
      int row = 0;
      if (!ParseAddress(name, &column, &row)) {
        return Value::Err("#NAME?");
      }
      const std::string address = MakeAddress(column, row);
      if (Peek() == ':') {
        ++pos_;
        Skip();
        const std::size_t rangeStart = pos_;
        while (pos_ < text_.size() &&
               (std::isalnum(static_cast<unsigned char>(text_[pos_])))) {
          ++pos_;
        }
        int column2 = 0;
        int row2 = 0;
        if (!ParseAddress(text_.substr(rangeStart, pos_ - rangeStart), &column2,
                          &row2)) {
          return Value::Err("#NAME?");
        }
        Value list;
        list.kind = Value::Kind::List;
        const int c1 = std::min(column, column2);
        const int c2 = std::max(column, column2);
        const int r1 = std::min(row, row2);
        const int r2 = std::max(row, row2);
        if (static_cast<long long>(c2 - c1 + 1) * (r2 - r1 + 1) > 10000) {
          return Value::Err("#RANGE!");
        }
        for (int r = r1; r <= r2; ++r) {
          for (int col = c1; col <= c2; ++col) {
            list.cells.push_back(MakeAddress(col, r));
          }
        }
        return list;
      }
      if (!evaluate) return Value::Num(0);
      return CellValue(address);
    }
    return Value::Err("#SYNTAX");
  }

  Value ParseFunction(const std::string& name, bool evaluate) {
    if (!Consume('(')) return Value::Err("#SYNTAX");
    if (name == "IF") {
      Value condition = ParseComparison(evaluate);
      if (condition.kind == Value::Kind::Error) return condition;
      if (!Consume(',')) return Value::Err("#SYNTAX");
      bool branch = evaluate && Truthy(condition);
      Value whenTrue = ParseComparison(branch);
      if (whenTrue.kind == Value::Kind::Error) return whenTrue;
      if (!Consume(',')) return Value::Err("#SYNTAX");
      Value whenFalse = ParseComparison(evaluate && !branch);
      if (whenFalse.kind == Value::Kind::Error) return whenFalse;
      if (!Consume(')')) return Value::Err("#SYNTAX");
      if (!evaluate) return Value::Num(0);
      return branch ? whenTrue : whenFalse;
    }
    std::vector<Value> args;
    for (;;) {
      args.push_back(ParseComparison(evaluate));
      if (args.back().kind == Value::Kind::Error) return args.back();
      if (Consume(',')) continue;
      break;
    }
    if (!Consume(')')) return Value::Err("#SYNTAX");
    if (!evaluate) return Value::Num(0);
    return ApplyFunction(name, args);
  }

  Value ApplyFunction(const std::string& name, const std::vector<Value>& args) {
    if (name == "ROUND") {
      if (args.size() != 2) return Value::Err("#ARGS!");
      const Value a = CoerceNumber(args[0]);
      const Value b = CoerceNumber(args[1]);
      if (a.kind == Value::Kind::Error) return a;
      if (b.kind == Value::Kind::Error) return b;
      const double factor = std::pow(10.0, b.number);
      return Value::Num(std::round(a.number * factor) / factor);
    }
    if (name == "ABS" || name == "SQRT") {
      if (args.size() != 1) return Value::Err("#ARGS!");
      const Value a = CoerceNumber(args[0]);
      if (a.kind == Value::Kind::Error) return a;
      if (name == "SQRT") {
        if (a.number < 0) return Value::Err("#NUM!");
        return Value::Num(std::sqrt(a.number));
      }
      return Value::Num(std::fabs(a.number));
    }
    if (name != "SUM" && name != "AVG" && name != "AVERAGE" && name != "MIN" &&
        name != "MAX" && name != "COUNT" && name != "COUNTA") {
      return Value::Err("#NAME?");
    }
    if (args.size() != 1) return Value::Err("#ARGS!");

    // Flatten the argument, resolving ranges and cell refs.
    std::vector<Value> items;
    const Value& argument = args[0];
    if (argument.kind == Value::Kind::List) {
      for (const std::string& address : argument.cells) {
        Value cell = CellValue(address);
        if (cell.kind == Value::Kind::Error) return cell;
        items.push_back(cell);
      }
    } else {
      items.push_back(argument);
    }
    if (name == "COUNTA") {
      double count = 0;
      for (const Value& item : items) {
        if (!IsBlank(item)) count += 1;
      }
      return Value::Num(count);
    }
    if (name == "COUNT") {
      double count = 0;
      for (const Value& item : items) {
        if (item.kind == Value::Kind::Number) count += 1;
      }
      return Value::Num(count);
    }
    double sum = 0.0;
    double numericCount = 0;
    double minimum = 0.0;
    double maximum = 0.0;
    bool first = true;
    for (const Value& item : items) {
      const Value number = CoerceNumber(item);
      if (number.kind != Value::Kind::Number) continue;  // text -> ignored
      if (IsBlank(item)) continue;
      sum += number.number;
      numericCount += 1;
      minimum = first ? number.number : std::min(minimum, number.number);
      maximum = first ? number.number : std::max(maximum, number.number);
      first = false;
    }
    if (name == "SUM") return Value::Num(sum);
    if (name == "AVG" || name == "AVERAGE") {
      if (numericCount == 0) return Value::Err("#DIV/0!");
      return Value::Num(sum / numericCount);
    }
    if (name == "MIN") return Value::Num(first ? 0.0 : minimum);
    return Value::Num(first ? 0.0 : maximum);
  }

  /// Recursive cell lookup with cycle detection + memoization.
  Value CellValue(const std::string& address) {
    auto cached = context_->memo->find(address);
    if (cached != context_->memo->end()) return cached->second;
    if (context_->visiting->count(address) > 0) {
      return Value::Err("#CYCLE!");
    }
    const nlohmann::json& cells = *context_->cells;
    if (!cells.contains(address) || !cells[address].is_object()) {
      Value empty;
      empty.kind = Value::Kind::Empty;
      context_->memo->emplace(address, empty);
      return empty;
    }
    const nlohmann::json& cell = cells[address];
    const std::string formula = cell.value("formula", std::string());
    if (formula.empty()) {
      Value value;
      const nlohmann::json& raw = cell.contains("value") ? cell["value"]
                                                         : nlohmann::json();
      if (raw.is_number()) {
        value.kind = Value::Kind::Number;
        value.number = raw.get<double>();
      } else if (raw.is_boolean()) {
        value.kind = Value::Kind::Bool;
        value.boolean = raw.get<bool>();
      } else if (raw.is_string()) {
        value.kind = Value::Kind::Text;
        value.text = raw.get<std::string>();
      } else {
        value.kind = Value::Kind::Empty;
      }
      context_->memo->emplace(address, value);
      return value;
    }
    context_->visiting->insert(address);
    std::string body = formula;
    if (!body.empty() && body[0] == '=') body = body.substr(1);
    Evaluator evaluator(body, context_);
    Value value = evaluator.Evaluate();
    context_->visiting->erase(address);
    if (value.kind != Value::Kind::Error) {
      context_->memo->emplace(address, value);
    }
    return value;
  }

  const std::string& text_;
  EvalContext* context_ = nullptr;
  std::size_t pos_ = 0;
};

/// Re-evaluates every formula cell; writes value/error back into `cells`.
/// Returns a JSON array of {address,error} pairs.
nlohmann::json EvaluateSheet(nlohmann::json& cells) {
  nlohmann::json errors = nlohmann::json::array();
  if (!cells.is_object()) return errors;
  std::vector<std::string> formulaAddresses;
  for (auto it = cells.begin(); it != cells.end(); ++it) {
    if (it.value().is_object() &&
        !it.value().value("formula", std::string()).empty()) {
      formulaAddresses.push_back(it.key());
    }
  }
  EvalContext context;
  context.cells = &cells;
  std::map<std::string, Value> memo;
  std::set<std::string> visiting;
  context.memo = &memo;
  context.visiting = &visiting;
  std::map<std::string, Value> results;
  for (const std::string& address : formulaAddresses) {
    if (memo.count(address) > 0) {
      results[address] = memo[address];
      continue;
    }
    std::string body = cells[address].value("formula", std::string());
    if (!body.empty() && body[0] == '=') body = body.substr(1);
    Evaluator evaluator(body, &context);
    Value value = evaluator.Evaluate();
    if (value.kind != Value::Kind::Error) memo.emplace(address, value);
    results[address] = value;
  }
  for (const std::string& address : formulaAddresses) {
    nlohmann::json& cell = cells[address];
    const Value& value = results[address];
    switch (value.kind) {
      case Value::Kind::Number:
        cell["value"] = value.number;
        cell.erase("error");
        break;
      case Value::Kind::Bool:
        cell["value"] = value.boolean;
        cell.erase("error");
        break;
      case Value::Kind::Text:
        cell["value"] = value.text;
        cell.erase("error");
        break;
      case Value::Kind::List: {
        std::string text;
        for (const std::string& ref : value.cells) {
          if (!text.empty()) text += ",";
          text += ref;
        }
        cell["value"] = text;
        cell.erase("error");
        break;
      }
      case Value::Kind::Empty:
        cell["value"] = 0.0;
        cell.erase("error");
        break;
      default: {
        cell["value"] = value.error;
        cell["error"] = value.error;
        nlohmann::json item;
        item["address"] = address;
        item["error"] = value.error;
        errors.push_back(std::move(item));
        break;
      }
    }
  }
  return errors;
}

class TableDomain : public DomainHandler {
 public:
  std::string name() const override { return "table"; }

  std::string handle(const std::string& op, const std::string& argsJson) override {
    const nlohmann::json args = ParseArgs(argsJson);
    if (op == "create") return Create(args);
    if (op == "setCell" || op == "set_cell") return SetCell(args);
    if (op == "getCell" || op == "get_cell") return GetCell(args);
    if (op == "setFormula" || op == "set_formula") return SetFormula(args);
    if (op == "sort") return Sort(args);
    if (op == "filter") return Filter(args);
    if (op == "setStyle" || op == "set_style") return SetStyle(args);
    if (op == "list") return List(args);
    return domainError("NotFound", "unknown table op: " + op);
  }

 private:
  /// Finds a "table" element; fills errorCode/errorMessage on failure.
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
    if (element.value("type", std::string()) != "table") {
      *errorCode = "InvalidArgument";
      *errorMessage = "element is not a table: " + elementId;
      return nullptr;
    }
    return &element;
  }

  /// Picks the element id from args: `tableId` first, then `elementId`.
  static std::string ElementIdArg(const nlohmann::json& args) {
    const std::string tableId = args.value("tableId", std::string());
    if (!tableId.empty()) return tableId;
    return args.value("elementId", std::string());
  }

  static nlohmann::json DefaultData() {
    nlohmann::json data;
    data["rows"] = 5;
    data["cols"] = 4;
    data["cells"] = nlohmann::json::object();
    data["cellStyles"] = nlohmann::json::object();
    return data;
  }

  /// Grows rows/cols so `column`/`row` fit.
  static void ExpandToFit(nlohmann::json& data, int column, int row) {
    if (data.value("rows", 0) < row) data["rows"] = row;
    if (data.value("cols", 0) < column + 1) data["cols"] = column + 1;
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
    element["type"] = "table";

    nlohmann::json data = DefaultData();
    if (element.contains("data") && element["data"].is_object()) {
      for (auto it = element["data"].begin(); it != element["data"].end(); ++it) {
        data[it.key()] = it.value();
      }
    }
    if (!data.contains("cols") && data.contains("columns")) {
      data["cols"] = data["columns"];
    }
    data.erase("columns");
    if (!data["cells"].is_object()) data["cells"] = nlohmann::json::object();
    if (!data["cellStyles"].is_object()) {
      data["cellStyles"] = nlohmann::json::object();
    }
    // Normalize provided cell addresses (a1 -> A1).
    nlohmann::json normalized = nlohmann::json::object();
    for (auto it = data["cells"].begin(); it != data["cells"].end(); ++it) {
      const std::string address = ToUpper(it.key());
      nlohmann::json cell = it.value().is_object() ? it.value()
                                                   : nlohmann::json::object();
      normalized[address] = std::move(cell);
    }
    data["cells"] = std::move(normalized);
    EvaluateSheet(data["cells"]);
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
    nlohmann::json result;
    result["element"] = created;
    result["elementId"] = elementId;
    result["pageId"] = pageId;
    result["type"] = "table";
    return domainOk(result.dump());
  }

  std::string SetCell(const nlohmann::json& args) {
    const std::string tableId = ElementIdArg(args);
    const std::string rawAddress = args.value("address", std::string());
    int column = 0;
    int row = 0;
    if (!ParseAddress(rawAddress, &column, &row)) {
      return domainError("InvalidArgument", "invalid cell address: " + rawAddress);
    }
    if (!args.contains("value")) {
      return domainError("InvalidArgument", "args.value is required");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), tableId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& data = (*element)["data"];
    const std::string address = MakeAddress(column, row);
    nlohmann::json cell = data["cells"].value(address, nlohmann::json::object());
    if (!cell.is_object()) cell = nlohmann::json::object();
    cell["value"] = args["value"];
    cell.erase("formula");
    cell.erase("error");
    data["cells"][address] = std::move(cell);
    ExpandToFit(data, column, row);
    EvaluateSheet(data["cells"]);
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["address"] = address;
    result["cell"] = data["cells"][address];
    result["tableId"] = tableId;
    return domainOk(result.dump());
  }

  std::string GetCell(const nlohmann::json& args) {
    const std::string tableId = ElementIdArg(args);
    const std::string rawAddress = args.value("address", std::string());
    int column = 0;
    int row = 0;
    if (!ParseAddress(rawAddress, &column, &row)) {
      return domainError("InvalidArgument", "invalid cell address: " + rawAddress);
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), tableId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    const std::string address = MakeAddress(column, row);
    nlohmann::json result;
    result["address"] = address;
    result["cell"] = (*element)["data"]["cells"].value(address,
                                                       nlohmann::json::object());
    result["tableId"] = tableId;
    return domainOk(result.dump());
  }

  std::string SetFormula(const nlohmann::json& args) {
    const std::string tableId = ElementIdArg(args);
    const std::string rawAddress = args.value("address", std::string());
    std::string formula = args.value("formula", std::string());
    int column = 0;
    int row = 0;
    if (!ParseAddress(rawAddress, &column, &row)) {
      return domainError("InvalidArgument", "invalid cell address: " + rawAddress);
    }
    if (formula.empty()) {
      return domainError("InvalidArgument", "args.formula is required");
    }
    if (formula[0] != '=') formula = "=" + formula;
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), tableId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& data = (*element)["data"];
    const std::string address = MakeAddress(column, row);
    nlohmann::json cell = data["cells"].value(address, nlohmann::json::object());
    if (!cell.is_object()) cell = nlohmann::json::object();
    cell["formula"] = formula;
    cell.erase("error");
    data["cells"][address] = std::move(cell);
    ExpandToFit(data, column, row);
    const nlohmann::json errors = EvaluateSheet(data["cells"]);
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["address"] = address;
    result["cell"] = data["cells"][address];
    result["errors"] = errors;
    result["tableId"] = tableId;
    return domainOk(result.dump());
  }

  std::string Sort(const nlohmann::json& args) {
    const std::string tableId = ElementIdArg(args);
    const std::string columnLetter = args.value("column", std::string());
    int column = 0;
    int ignoredRow = 0;
    if (!ParseAddress(columnLetter + "1", &column, &ignoredRow)) {
      return domainError("InvalidArgument", "invalid column: " + columnLetter);
    }
    const bool ascending = args.value("ascending", true);
    const bool hasHeader = args.value("hasHeader", args.value("header", true));
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), tableId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    nlohmann::json& data = (*element)["data"];
    nlohmann::json& cells = data["cells"];
    const int rows = data.value("rows", 0);
    const int startRow = hasHeader ? 2 : 1;
    std::vector<int> order;
    for (int row = startRow; row <= rows; ++row) order.push_back(row);

    auto sortKey = [&cells, column](int row, int* category, double* number,
                                    std::string* text) {
      *category = 0;
      *number = 0.0;
      *text = std::string();
      const std::string address = MakeAddress(column, row);
      if (!cells.contains(address)) return;
      const nlohmann::json& cell = cells[address];
      const nlohmann::json& value =
          cell.is_object() && cell.contains("value") ? cell["value"]
                                                     : nlohmann::json();
      if (value.is_number()) {
        *category = 1;
        *number = value.get<double>();
      } else if (value.is_boolean()) {
        *category = 1;
        *number = value.get<bool>() ? 1.0 : 0.0;
      } else if (value.is_string()) {
        *category = 2;
        *text = value.get<std::string>();
      }
    };
    std::stable_sort(order.begin(), order.end(), [&](int a, int b) {
      int categoryA = 0;
      int categoryB = 0;
      double numberA = 0.0;
      double numberB = 0.0;
      std::string textA;
      std::string textB;
      sortKey(a, &categoryA, &numberA, &textA);
      sortKey(b, &categoryB, &numberB, &textB);
      bool less;
      if (categoryA != categoryB) {
        less = categoryA < categoryB;
      } else if (categoryA == 1) {
        less = numberA < numberB;
      } else {
        less = textA < textB;
      }
      return ascending ? less : !less;
    });

    // Rebuild cells with the new row order.
    nlohmann::json rebuilt = nlohmann::json::object();
    for (auto it = cells.begin(); it != cells.end(); ++it) {
      int cellColumn = 0;
      int cellRow = 0;
      if (!ParseAddress(it.key(), &cellColumn, &cellRow)) continue;
      if (cellRow < startRow) {
        rebuilt[it.key()] = it.value();
      }
    }
    for (std::size_t i = 0; i < order.size(); ++i) {
      const int oldRow = order[i];
      const int newRow = startRow + static_cast<int>(i);
      for (int col = 0; col < data.value("cols", 0); ++col) {
        const std::string oldAddress = MakeAddress(col, oldRow);
        if (!cells.contains(oldAddress)) continue;
        rebuilt[MakeAddress(col, newRow)] = cells[oldAddress];
      }
    }
    cells = std::move(rebuilt);
    EvaluateSheet(cells);
    (*element)["updatedAt"] = timeMillis();

    nlohmann::json result;
    result["order"] = order;
    result["rowCount"] = static_cast<int>(order.size());
    result["tableId"] = tableId;
    return domainOk(result.dump());
  }

  std::string Filter(const nlohmann::json& args) {
    const std::string tableId = ElementIdArg(args);
    const std::string columnLetter = args.value("column", std::string());
    std::string op = args.value("op", std::string("="));
    if (op == "==") op = "=";
    if (op == "eq") op = "=";
    if (op == "ne") op = "!=";
    if (op == "gt") op = ">";
    if (op == "lt") op = "<";
    if (op == "ge") op = ">=";
    if (op == "le") op = "<=";
    if(op.empty()) return domainError("InvalidArgument", "args.op is required");
    const bool hasValue = args.contains("value");
    if (!hasValue) return domainError("InvalidArgument", "args.value is required");
    int column = 0;
    int ignoredRow = 0;
    if (!ParseAddress(columnLetter + "1", &column, &ignoredRow)) {
      return domainError("InvalidArgument", "invalid column: " + columnLetter);
    }
    const bool hasHeader = args.value("hasHeader", args.value("header", true));
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), tableId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    const nlohmann::json& data = (*element)["data"];
    const nlohmann::json& cells = data["cells"];
    const int rows = data.value("rows", 0);
    const int startRow = hasHeader ? 2 : 1;
    const nlohmann::json& expected = args["value"];
    nlohmann::json matches = nlohmann::json::array();
    for (int row = startRow; row <= rows; ++row) {
      const std::string address = MakeAddress(column, row);
      nlohmann::json actual = nlohmann::json();
      if (cells.contains(address) && cells[address].is_object()) {
        actual = cells[address].value("value", nlohmann::json());
      }
      bool match = false;
      if (op == "contains") {
        const std::string needle =
            expected.is_string() ? expected.get<std::string>()
                                 : expected.dump();
        std::string haystack;
        if (actual.is_string()) haystack = actual.get<std::string>();
        else if (!actual.is_null()) haystack = actual.dump();
        match = haystack.find(needle) != std::string::npos;
      } else if (actual.is_number() && expected.is_number()) {
        const double a = actual.get<double>();
        const double b = expected.get<double>();
        if (op == "=") match = a == b;
        else if (op == "!=") match = a != b;
        else if (op == ">") match = a > b;
        else if (op == "<") match = a < b;
        else if (op == ">=") match = a >= b;
        else if (op == "<=") match = a <= b;
      } else if (actual.is_string() && expected.is_string()) {
        const std::string a = actual.get<std::string>();
        const std::string b = expected.get<std::string>();
        if (op == "=") match = a == b;
        else if (op == "!=") match = a != b;
        else if (op == ">") match = a > b;
        else if (op == "<") match = a < b;
        else if (op == ">=") match = a >= b;
        else if (op == "<=") match = a <= b;
      } else if (op == "!=") {
        match = !(actual.is_null() && expected.is_null());
      }
      if (match) matches.push_back(row);
    }
    nlohmann::json result;
    result["count"] = static_cast<int>(matches.size());
    result["matches"] = std::move(matches);
    result["tableId"] = tableId;
    return domainOk(result.dump());
  }

  std::string SetStyle(const nlohmann::json& args) {
    const std::string tableId = ElementIdArg(args);
    if (!args.contains("style") || !args["style"].is_object()) {
      return domainError("InvalidArgument", "args.style is required");
    }
    std::lock_guard<std::mutex> lock(SceneStore::instance().mutex());
    std::string code;
    std::string message;
    nlohmann::json* element = Find(SceneStore::instance(), tableId, &code, &message);
    if (element == nullptr) return domainError(code, message);

    const nlohmann::json& style = args["style"];
    const std::string cellRange = args.value("cellRange", std::string());
    if (!cellRange.empty()) {
      nlohmann::json merged =
          (*element)["data"]["cellStyles"].value(cellRange,
                                                 nlohmann::json::object());
      if (!merged.is_object()) merged = nlohmann::json::object();
      for (auto it = style.begin(); it != style.end(); ++it) {
        merged[it.key()] = it.value();
      }
      (*element)["data"]["cellStyles"][ToUpper(cellRange)] = std::move(merged);
    } else {
      nlohmann::json merged = element->value("style", nlohmann::json::object());
      if (!merged.is_object()) merged = nlohmann::json::object();
      for (auto it = style.begin(); it != style.end(); ++it) {
        merged[it.key()] = it.value();
      }
      (*element)["style"] = std::move(merged);
    }
    (*element)["updatedAt"] = timeMillis();
    nlohmann::json result;
    result["element"] = *element;
    result["elementId"] = tableId;
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
      if (element.value("type", std::string()) != "table") continue;
      nlohmann::json summary = SceneStore::elementSummary(element);
      int rows = 0;
      int cols = 0;
      int cellCount = 0;
      if (element.contains("data") && element["data"].is_object()) {
        const nlohmann::json& data = element["data"];
        rows = data.value("rows", 0);
        cols = data.value("cols", 0);
        if (data.contains("cells") && data["cells"].is_object()) {
          cellCount = static_cast<int>(data["cells"].size());
        }
      }
      summary["rows"] = rows;
      summary["cols"] = cols;
      summary["cellCount"] = cellCount;
      elements.push_back(std::move(summary));
    }
    nlohmann::json result;
    result["elements"] = std::move(elements);
    result["count"] = static_cast<int>(result["elements"].size());
    return domainOk(result.dump());
  }
};

}  // namespace

WB_REGISTER_DOMAIN(TableDomain)

}  // namespace wb
