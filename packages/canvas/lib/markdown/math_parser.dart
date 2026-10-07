/// LaTeX 子集解析器（零依赖自研）：公式源 → 数学布局树。
///
/// 覆盖方案 §16 必须清单的「常用 LaTeX」：分式 / 上下标 / 根号 /
/// 求和积分等大运算符 / 希腊字母 / 基础矩阵 / 文本命令；
/// 解析失败不抛出，产出 [WbMathError] 节点（方案 §20 容错语义）。
library;

/// 数学节点基类（布局树）。
sealed class WbMathNode {
  /// 创建节点。
  const WbMathNode();
}

/// 水平序列（最常用容器）。
class WbMathRow extends WbMathNode {
  /// 创建序列。
  const WbMathRow(this.children);

  /// 子节点（按序水平排列）。
  final List<WbMathNode> children;
}

/// 普通字符原子（含映射后的希腊字母 / 运算符符号）。
class WbMathAtom extends WbMathNode {
  /// 创建原子。
  const WbMathAtom(this.text);

  /// 显示文本。
  final String text;
}

/// 分式（`\frac{a}{b}`）。
class WbMathFrac extends WbMathNode {
  /// 创建分式。
  const WbMathFrac({required this.numerator, required this.denominator});

  /// 分子。
  final WbMathNode numerator;

  /// 分母。
  final WbMathNode denominator;
}

/// 根号（`\sqrt{x}` / `\sqrt[n]{x}`）。
class WbMathSqrt extends WbMathNode {
  /// 创建根号。
  const WbMathSqrt({required this.child, this.index});

  /// 被开方内容。
  final WbMathNode child;

  /// 开方次数（可空）。
  final WbMathNode? index;
}

/// 上下标（`x^2` / `x_i` / `x_i^2`）。
class WbMathScript extends WbMathNode {
  /// 创建上下标。
  const WbMathScript({required this.base, this.sup, this.sub});

  /// 基座。
  final WbMathNode base;

  /// 上标（可空）。
  final WbMathNode? sup;

  /// 下标（可空）。
  final WbMathNode? sub;
}

/// 大运算符（`\sum` / `\int` / `\prod` / `\lim`）。
class WbMathBigOp extends WbMathNode {
  /// 创建大运算符。
  const WbMathBigOp({required this.symbol, this.sub, this.sup});

  /// 运算符符号（∑ / ∫ 等）。
  final String symbol;

  /// 下标（可空）。
  final WbMathNode? sub;

  /// 上标（可空）。
  final WbMathNode? sup;
}

/// 自适应定界符（`\left( ... \right)`）。
class WbMathDelim extends WbMathNode {
  /// 创建定界符。
  const WbMathDelim({
    required this.left,
    required this.right,
    required this.child,
  });

  /// 左定界符（空串 = 不可见 `\.`）。
  final String left;

  /// 右定界符（空串 = 不可见 `\.`）。
  final String right;

  /// 内容。
  final WbMathNode child;
}

/// 矩阵 / 多行环境（matrix / pmatrix / bmatrix / cases 等）。
class WbMathMatrix extends WbMathNode {
  /// 创建矩阵。
  const WbMathMatrix({
    required this.rows,
    this.left = '',
    this.right = '',
  });

  /// 行 × 列节点。
  final List<List<WbMathNode>> rows;

  /// 左定界符。
  final String left;

  /// 右定界符。
  final String right;
}

/// 空白（`\,` / `\;` / `\quad` / `\qquad`，单位 em）。
class WbMathSpace extends WbMathNode {
  /// 创建空白。
  const WbMathSpace(this.widthEm);

  /// 宽度（em）。
  final double widthEm;
}

/// 解析容错节点：非法公式不抛出，渲染为错误提示并保留 source。
class WbMathError extends WbMathNode {
  /// 创建错误节点。
  const WbMathError(this.message);

  /// 错误信息。
  final String message;
}

/// LaTeX 子集解析入口（纯函数；不抛异常）。
abstract final class WbMathParser {
  /// 解析 LaTeX 源为数学布局树；非法输入返回 [WbMathError]。
  static WbMathNode parse(String latex) {
    try {
      final _MathParser parser = _MathParser(latex);
      final WbMathNode node = parser.parseAll();
      return node;
    } catch (error) {
      return WbMathError('公式解析失败：$error');
    }
  }

  /// 常用希腊字母 / 运算符 / 数学符号映射（命令名 → 显示文本）。
  static const Map<String, String> symbolMap = <String, String>{
    // 小写希腊字母。
    'alpha': 'α', 'beta': 'β', 'gamma': 'γ', 'delta': 'δ',
    'epsilon': 'ε', 'varepsilon': 'ε', 'zeta': 'ζ', 'eta': 'η',
    'theta': 'θ', 'vartheta': 'ϑ', 'iota': 'ι', 'kappa': 'κ',
    'lambda': 'λ', 'mu': 'μ', 'nu': 'ν', 'xi': 'ξ',
    'pi': 'π', 'varpi': 'ϖ', 'rho': 'ρ', 'sigma': 'σ',
    'varsigma': 'ς', 'tau': 'τ', 'upsilon': 'υ', 'phi': 'φ',
    'varphi': 'ϕ', 'chi': 'χ', 'psi': 'ψ', 'omega': 'ω',
    // 大写希腊字母。
    'Gamma': 'Γ', 'Delta': 'Δ', 'Theta': 'Θ', 'Lambda': 'Λ',
    'Xi': 'Ξ', 'Pi': 'Π', 'Sigma': 'Σ', 'Upsilon': 'Υ',
    'Phi': 'Φ', 'Psi': 'Ψ', 'Omega': 'Ω',
    // 运算符与关系。
    'times': '×', 'cdot': '·', 'div': '÷', 'pm': '±', 'mp': '∓',
    'leq': '≤', 'le': '≤', 'geq': '≥', 'ge': '≥', 'neq': '≠',
    'ne': '≠', 'approx': '≈', 'equiv': '≡', 'sim': '∼',
    'propto': '∝', 'infty': '∞', 'partial': '∂', 'nabla': '∇',
    // 集合与逻辑。
    'forall': '∀', 'exists': '∃', 'nexists': '∄', 'emptyset': '∅',
    'subset': '⊂', 'subseteq': '⊆', 'supset': '⊃', 'supseteq': '⊇',
    'in': '∈', 'notin': '∉', 'cup': '∪', 'cap': '∩', 'setminus': '∖',
    'land': '∧', 'lor': '∨', 'lnot': '¬',
    // 箭头。
    'to': '→', 'gets': '←', 'rightarrow': '→', 'leftarrow': '←',
    'leftrightarrow': '↔', 'Rightarrow': '⇒', 'Leftarrow': '⇐',
    'Leftrightarrow': '⇔', 'mapsto': '↦', 'uparrow': '↑',
    'downarrow': '↓',
    // 杂项。
    'angle': '∠', 'perp': '⊥', 'parallel': '∥', 'prime': '′',
    'cdots': '⋯', 'ldots': '…', 'dots': '…', 'vdots': '⋮',
    'ddots': '⋱', 'degree': '°', 'circ': '∘', 'star': '⋆',
    'ast': '∗', 'oplus': '⊕', 'ominus': '⊖', 'otimes': '⊗',
    'ell': 'ℓ', 'hbar': 'ℏ', 'surd': '√', 'neg': '¬',
    'therefore': '∴', 'because': '∵', 'sqrtsign': '√',
  };

  /// 大运算符命令 → 符号。
  static const Map<String, String> bigOpMap = <String, String>{
    'sum': '∑', 'prod': '∏', 'coprod': '∐',
    'int': '∫', 'iint': '∬', 'iiint': '∭', 'oint': '∮',
    'lim': 'lim', 'limsup': 'lim sup', 'liminf': 'lim inf',
    'max': 'max', 'min': 'min', 'sup': 'sup', 'inf': 'inf',
    'bigcup': '⋃', 'bigcap': '⋂', 'bigoplus': '⨁', 'bigotimes': '⨂',
  };
}

/// 手写递归下降解析器（单次遍历，无异常路径）。
class _MathParser {
  _MathParser(this.src);

  final String src;
  int pos = 0;

  /// 解析整个公式：顶层序列；孤立 `\\` 视作空白分隔。
  WbMathNode parseAll() {
    final List<WbMathNode> parts = <WbMathNode>[];
    while (true) {
      final WbMathNode row = _parseRow();
      if (row is WbMathRow && row.children.isEmpty) {
        break;
      }
      parts.add(row);
      if (_atDoubleBackslash()) {
        pos += 2; // 顶层 `\\`：视作普通空白，继续。
        continue;
      }
      break;
    }
    if (parts.isEmpty) {
      return const WbMathRow(<WbMathNode>[]);
    }
    if (parts.length == 1) {
      return parts.first;
    }
    return WbMathRow(parts);
  }

  // ---- 序列与原子 ---------------------------------------------------------

  /// 解析水平序列，遇到序列终止符（`}` `&` `\\` `\right` `\end`）停止。
  WbMathNode _parseRow() {
    final List<WbMathNode> children = <WbMathNode>[];
    while (pos < src.length) {
      _skipSpaces();
      if (pos >= src.length) {
        break;
      }
      if (_isRowStop()) {
        break;
      }
      final int before = pos;
      children.add(_parseScripted());
      if (pos == before) {
        pos++; // 防御：任何未消费字符都跳过，避免死循环。
      }
    }
    if (children.length == 1) {
      return children.first;
    }
    return WbMathRow(children);
  }

  bool _isRowStop() {
    final String ch = src[pos];
    if (ch == '}' || ch == '&') {
      return true;
    }
    if (_atDoubleBackslash()) {
      return true;
    }
    if (src.startsWith(r'\right', pos) || src.startsWith(r'\end', pos)) {
      return true;
    }
    return false;
  }

  bool _atDoubleBackslash() =>
      pos + 1 < src.length && src[pos] == r'\' && src[pos + 1] == r'\';

  void _skipSpaces() {
    while (pos < src.length) {
      final String ch = src[pos];
      if (ch == ' ' || ch == '\t' || ch == '\n') {
        pos++;
        continue;
      }
      break;
    }
  }

  /// 解析原子 + 可选上下标（`^` / `_`，顺序任意）。
  WbMathNode _parseScripted() {
    final WbMathNode base = _parseAtom();
    WbMathNode? sup;
    WbMathNode? sub;
    while (true) {
      _skipSpaces();
      if (pos >= src.length) {
        break;
      }
      final String ch = src[pos];
      if (ch != '^' && ch != '_') {
        break;
      }
      pos++;
      _skipSpaces();
      final WbMathNode arg = _parseScriptArg();
      if (ch == '^') {
        sup = arg;
      } else {
        sub = arg;
      }
    }
    if (sup == null && sub == null) {
      return base;
    }
    if (base is WbMathBigOp) {
      return WbMathBigOp(
        symbol: base.symbol,
        sub: sub ?? base.sub,
        sup: sup ?? base.sup,
      );
    }
    return WbMathScript(base: base, sup: sup, sub: sub);
  }

  /// 上/下标参数：`{...}` 组或单个原子。
  WbMathNode _parseScriptArg() {
    _skipSpaces();
    if (pos >= src.length) {
      return const WbMathAtom('');
    }
    if (src[pos] == '{') {
      pos++;
      final WbMathNode node = _parseRow();
      _expectCloseBrace();
      return node;
    }
    return _parseAtom();
  }

  /// 解析单个原子：组 / 命令 / 普通字符。
  WbMathNode _parseAtom() {
    if (pos >= src.length) {
      return const WbMathAtom('');
    }
    final String ch = src[pos];
    if (ch == '{') {
      pos++;
      final WbMathNode node = _parseRow();
      _expectCloseBrace();
      return node;
    }
    if (ch == r'\') {
      return _parseCommand();
    }
    if (ch == '}' || ch == '&' || ch == '\$') {
      return const WbMathAtom('');
    }
    // 普通字符序列（数字 / 拉丁字母 / 用户自定义符号）。
    final int start = pos;
    while (pos < src.length && !_isSpecial(src[pos])) {
      pos++;
    }
    return WbMathAtom(src.substring(start, pos));
  }

  bool _isSpecial(String ch) =>
      ch == r'\' ||
      ch == '{' ||
      ch == '}' ||
      ch == '^' ||
      ch == '_' ||
      ch == '&' ||
      ch == '\$' ||
      ch == ' ' ||
      ch == '\t' ||
      ch == '\n';

  void _expectCloseBrace() {
    _skipSpaces();
    if (pos < src.length && src[pos] == '}') {
      pos++;
    }
  }

  // ---- 命令 ---------------------------------------------------------------

  WbMathNode _parseCommand() {
    pos++; // 消费 `\`。
    if (pos >= src.length) {
      return const WbMathAtom(r'\');
    }
    final String ch = src[pos];
    if (!_isAsciiLetter(ch)) {
      // 单字符命令：\, \; \! \: \ 等空白；\{ \} 等字面量。
      pos++;
      switch (ch) {
        case ',':
          return const WbMathSpace(0.17);
        case ';':
          return const WbMathSpace(0.28);
        case ':':
          return const WbMathSpace(0.22);
        case '!':
          return const WbMathSpace(-0.17);
        case ' ':
          return const WbMathSpace(0.25);
        case r'\':
          return const WbMathAtom(' '); // `\\` 行分隔在非矩阵上下文视作空白。
        case '{':
          return const WbMathAtom('{');
        case '}':
          return const WbMathAtom('}');
        case '_':
          return const WbMathAtom('_');
        case '%':
          return const WbMathAtom('%');
        case '#':
          return const WbMathAtom('#');
        case '&':
          return const WbMathAtom('&');
        default:
          return WbMathAtom(ch);
      }
    }
    final int start = pos;
    while (pos < src.length && _isAsciiLetter(src[pos])) {
      pos++;
    }
    final String name = src.substring(start, pos);
    return _dispatchCommand(name);
  }

  bool _isAsciiLetter(String ch) {
    final int c = ch.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  }

  WbMathNode _dispatchCommand(String name) {
    switch (name) {
      case 'frac':
      case 'dfrac':
      case 'tfrac':
        return WbMathFrac(
          numerator: _parseRequiredGroup(),
          denominator: _parseRequiredGroup(),
        );
      case 'sqrt':
        return _parseSqrt();
      case 'left':
        return _parseDelim();
      case 'begin':
        return _parseEnvironment();
      case 'text':
      case 'mathrm':
      case 'mathbf':
      case 'mathit':
      case 'mathsf':
      case 'mathtt':
      case 'operatorname':
        return WbMathAtom(_readGroupText());
      default:
        final String? bigOp = WbMathParser.bigOpMap[name];
        if (bigOp != null) {
          return WbMathBigOp(symbol: bigOp);
        }
        final String? symbol = WbMathParser.symbolMap[name];
        if (symbol != null) {
          return WbMathAtom(symbol);
        }
        // 未知命令：以原文显示（保留可读性，不抛错）。
        return WbMathAtom(name);
    }
  }

  WbMathNode _parseSqrt() {
    _skipSpaces();
    WbMathNode? index;
    if (pos < src.length && src[pos] == '[') {
      pos++;
      final int start = pos;
      while (pos < src.length && src[pos] != ']') {
        pos++;
      }
      final String raw = src.substring(start, pos);
      if (pos < src.length) {
        pos++; // 消费 `]`。
      }
      index = WbMathParser.parse(raw);
    }
    return WbMathSqrt(child: _parseRequiredGroup(), index: index);
  }

  /// 必选组 `{...}`；缺失时容错返回空原子。
  WbMathNode _parseRequiredGroup() {
    _skipSpaces();
    if (pos < src.length && src[pos] == '{') {
      pos++;
      final WbMathNode node = _parseRow();
      _expectCloseBrace();
      return node;
    }
    // 容错：无 `{}` 时取单个原子（如 `\frac12`）。
    return _parseAtom();
  }

  /// 读取 `{...}` 内容为纯文本（`\text{}` 等；嵌套花括号计入深度）。
  String _readGroupText() {
    _skipSpaces();
    if (pos >= src.length || src[pos] != '{') {
      return '';
    }
    pos++;
    final StringBuffer buffer = StringBuffer();
    int depth = 1;
    while (pos < src.length && depth > 0) {
      final String ch = src[pos];
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          pos++;
          break;
        }
      }
      buffer.write(ch);
      pos++;
    }
    return buffer.toString();
  }

  // ---- 定界符 -------------------------------------------------------------

  /// `\left<delim> ... \right<delim>`。
  WbMathNode _parseDelim() {
    _skipSpaces();
    final String left = _readDelimiter();
    final WbMathNode child = _parseRow();
    _skipSpaces();
    String right = '';
    if (src.startsWith(r'\right', pos)) {
      pos += r'\right'.length;
      _skipSpaces();
      right = _readDelimiter();
    }
    return WbMathDelim(left: left, right: right, child: child);
  }

  /// 读取一个定界符（单字符或命令形式；`.` 表示不可见）。
  String _readDelimiter() {
    if (pos >= src.length) {
      return '';
    }
    final String ch = src[pos];
    if (ch == r'\') {
      final int start = pos;
      pos++;
      if (pos < src.length && _isAsciiLetter(src[pos])) {
        while (pos < src.length && _isAsciiLetter(src[pos])) {
          pos++;
        }
      } else if (pos < src.length) {
        pos++;
      }
      final String name = src.substring(start + 1, pos);
      switch (name) {
        case '.':
          return '';
        case '{':
          return '{';
        case '}':
          return '}';
        case 'langle':
          return '⟨';
        case 'rangle':
          return '⟩';
        case 'lvert':
        case 'rvert':
          return '|';
        case 'lVert':
        case 'rVert':
          return '‖';
        case 'lfloor':
          return '⌊';
        case 'rfloor':
          return '⌋';
        case 'lceil':
          return '⌈';
        case 'rceil':
          return '⌉';
        default:
          return WbMathParser.symbolMap[name] ?? name;
      }
    }
    if (ch == '.') {
      pos++;
      return '';
    }
    pos++;
    return ch;
  }

  // ---- 矩阵环境 -----------------------------------------------------------

  /// `\begin{env} ... \end{env}`（matrix / pmatrix / bmatrix / cases 等）。
  WbMathNode _parseEnvironment() {
    final String env = _readGroupText();
    final (String, String) delims = _envDelimiters(env);
    final List<List<WbMathNode>> rows = <List<WbMathNode>>[];
    List<WbMathNode> row = <WbMathNode>[];
    while (pos < src.length) {
      _skipSpaces();
      if (pos >= src.length) {
        break;
      }
      if (src.startsWith(r'\end', pos)) {
        pos += r'\end'.length;
        _readGroupText(); // 消费 `{env}`。
        break;
      }
      if (src[pos] == '&') {
        pos++;
        continue; // 列分隔：序列已由 _parseRow 断开，此处仅消费。
      }
      if (_atDoubleBackslash()) {
        pos += 2;
        _skipBracketSpacing();
        rows.add(row);
        row = <WbMathNode>[];
        continue;
      }
      final int before = pos;
      row.add(_parseRow());
      if (pos == before) {
        pos++; // 防御：避免死循环。
      }
    }
    if (row.isNotEmpty || rows.isEmpty) {
      rows.add(row);
    }
    return WbMathMatrix(rows: rows, left: delims.$1, right: delims.$2);
  }

  /// `\\[4pt]` 形式行距参数（`[...]`）的容错跳过。
  void _skipBracketSpacing() {
    _skipSpaces();
    if (pos < src.length && src[pos] == '[') {
      final int close = src.indexOf(']', pos);
      if (close > 0) {
        pos = close + 1;
      }
    }
  }

  (String, String) _envDelimiters(String env) {
    switch (env) {
      case 'pmatrix':
        return ('(', ')');
      case 'bmatrix':
        return ('[', ']');
      case 'Bmatrix':
        return ('{', '}');
      case 'vmatrix':
        return ('|', '|');
      case 'Vmatrix':
        return ('‖', '‖');
      case 'cases':
        return ('{', '');
      default:
        return ('', '');
    }
  }
}
