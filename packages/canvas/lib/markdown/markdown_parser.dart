/// Markdown 解析器（GFM 子集，零依赖自研）。
///
/// 覆盖方案 §16 必须清单：标题 / 段落 / 粗体 / 斜体 / 删除线 / 列表 /
/// 引用 / 链接 / 分割线 / 表格 / 图片 / 代码块 / 行内代码；
/// Math / Mermaid 作为独立块节点（分别在 `math_parser` / `mermaid_parser`
/// 中二次解析）。解析失败不抛出：尽力产出 AST（容错语义，方案 §20）。
library;

import 'markdown_ast.dart';

/// Markdown 解析入口（纯函数）。
abstract final class WbMarkdownParser {
  static final RegExp _fenceRe = RegExp(r'^(\s*)(`{3,}|~{3,})\s*([^`~]*)$');
  static final RegExp _headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
  static final RegExp _dividerRe =
      RegExp(r'^\s{0,3}((?:-\s*){3,}|(?:\*\s*){3,}|(?:_\s*){3,})$');
  static final RegExp _quoteRe = RegExp(r'^\s{0,3}>\s?(.*)$');
  static final RegExp _listRe =
      RegExp(r'^(\s*)(?:(\d{1,9})[.)]|([-*+]))\s+(.*)$');

  /// 解析源文本为文档 AST。
  static WbMdDocument parse(String source) {
    final String normalized =
        source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = normalized.split('\n');
    return WbMdDocument(blocks: _parseBlocks(lines, 0, lines.length));
  }

  // ---- 块级解析 -----------------------------------------------------------

  static List<WbMdBlock> _parseBlocks(List<String> lines, int start, int end) {
    final List<WbMdBlock> blocks = <WbMdBlock>[];
    int i = start;
    while (i < end) {
      final String line = lines[i];
      if (line.trim().isEmpty) {
        i++;
        continue;
      }
      // 围栏代码块 / Mermaid。
      final RegExpMatch? fence = _fenceRe.firstMatch(line);
      if (fence != null) {
        i = _parseFence(lines, i, end, fence, blocks);
        continue;
      }
      // 块级公式 $$...$$。
      if (_isMathFence(line)) {
        i = _parseMathBlock(lines, i, end, blocks);
        continue;
      }
      // 标题。
      final RegExpMatch? heading = _headingRe.firstMatch(line);
      if (heading != null) {
        blocks.add(WbMdHeading(
          level: heading.group(1)!.length,
          inlines: parseInline(_stripTrailingHashes(heading.group(2)!)),
        ));
        i++;
        continue;
      }
      // 分割线。
      if (_dividerRe.hasMatch(line)) {
        blocks.add(const WbMdDivider());
        i++;
        continue;
      }
      // 引用。
      if (_quoteRe.hasMatch(line)) {
        i = _parseQuote(lines, i, end, blocks);
        continue;
      }
      // 表格（当前行含 | 且下一行为分隔行）。
      if (line.contains('|') && _isTableSeparator(lines, i + 1, end)) {
        i = _parseTable(lines, i, end, blocks);
        continue;
      }
      // 列表。
      if (_listRe.hasMatch(line)) {
        i = _parseList(lines, i, end, blocks);
        continue;
      }
      // 段落（连续行合并，遇空行或新块起始行停止）。
      i = _parseParagraph(lines, i, end, blocks);
    }
    return blocks;
  }

  /// 围栏代码块：```lang ... ```；mermaid 语言产出独立图表节点。
  static int _parseFence(
    List<String> lines,
    int i,
    int end,
    RegExpMatch fence,
    List<WbMdBlock> blocks,
  ) {
    final String marker = fence.group(2)!;
    final String language = fence.group(3)!.trim();
    final String close = marker.substring(0, 3);
    int j = i + 1;
    while (j < end) {
      if (lines[j].trimLeft().startsWith(close)) {
        break;
      }
      j++;
    }
    final int contentEnd = j < end ? j : end;
    final String code = lines.sublist(i + 1, contentEnd).join('\n');
    if (language.toLowerCase() == 'mermaid') {
      blocks.add(WbMdMermaidBlock(code: code));
    } else {
      blocks.add(WbMdCodeBlock(language: language, code: code));
    }
    return j < end ? j + 1 : end;
  }

  static bool _isMathFence(String line) => line.trim().startsWith(r'$$');

  /// 块级公式：单行 `$$...$$` 或跨行 `$$` 围栏。
  static int _parseMathBlock(
    List<String> lines,
    int i,
    int end,
    List<WbMdBlock> blocks,
  ) {
    final String trimmed = lines[i].trim();
    if (trimmed.length > 4 && trimmed.endsWith(r'$$')) {
      blocks.add(WbMdMathBlock(
        latex: trimmed.substring(2, trimmed.length - 2).trim(),
      ));
      return i + 1;
    }
    if (trimmed == r'$$') {
      final StringBuffer buffer = StringBuffer();
      int j = i + 1;
      while (j < end && lines[j].trim() != r'$$') {
        buffer.writeln(lines[j]);
        j++;
      }
      blocks.add(WbMdMathBlock(latex: buffer.toString().trim()));
      return j < end ? j + 1 : end;
    }
    // `$$公式` 同行开头但未闭合：整行余下部分为公式（容错）。
    blocks.add(WbMdMathBlock(latex: trimmed.substring(2).trim()));
    return i + 1;
  }

  /// 引用块：连续 `>` 行（含空行分隔但下一行仍为引用）递归解析。
  static int _parseQuote(
    List<String> lines,
    int i,
    int end,
    List<WbMdBlock> blocks,
  ) {
    final List<String> inner = <String>[];
    int j = i;
    while (j < end) {
      final RegExpMatch? match = _quoteRe.firstMatch(lines[j]);
      if (match != null) {
        inner.add(match.group(1)!);
        j++;
        continue;
      }
      if (lines[j].trim().isEmpty) {
        int k = j + 1;
        while (k < end && lines[k].trim().isEmpty) {
          k++;
        }
        if (k < end && _quoteRe.hasMatch(lines[k])) {
          inner.add('');
          j++;
          continue;
        }
      }
      break;
    }
    blocks.add(WbMdQuote(blocks: _parseBlocks(inner, 0, inner.length)));
    return j;
  }

  /// 表格分隔行判定（`|---|:--:|`）。
  static bool _isTableSeparator(List<String> lines, int index, int end) {
    if (index >= end) {
      return false;
    }
    return _tableAligns(lines[index]) != null;
  }

  /// 解析分隔行为对齐列表；非分隔行返回 null。
  static List<WbMdTableAlign>? _tableAligns(String line) {
    final String trimmed = line.trim();
    if (!trimmed.contains('-')) {
      return null;
    }
    final List<String> cells = _splitTableRow(trimmed);
    if (cells.isEmpty) {
      return null;
    }
    final List<WbMdTableAlign> aligns = <WbMdTableAlign>[];
    for (final String cell in cells) {
      final String value = cell.trim();
      final bool valid = RegExp(r'^:?-{1,}:?$').hasMatch(value);
      if (!valid) {
        return null;
      }
      final bool left = value.startsWith(':');
      final bool right = value.endsWith(':');
      aligns.add(left && right
          ? WbMdTableAlign.center
          : right
              ? WbMdTableAlign.right
              : WbMdTableAlign.left);
    }
    return aligns;
  }

  /// 表格：表头 + 分隔行 + 数据行。
  static int _parseTable(
    List<String> lines,
    int i,
    int end,
    List<WbMdBlock> blocks,
  ) {
    final List<List<WbMdInline>> header = <List<WbMdInline>>[
      for (final String cell in _splitTableRow(lines[i]))
        parseInline(cell.trim()),
    ];
    final List<WbMdTableAlign> aligns = _tableAligns(lines[i + 1])!;
    while (aligns.length < header.length) {
      aligns.add(WbMdTableAlign.left);
    }
    final List<List<List<WbMdInline>>> rows = <List<List<WbMdInline>>>[];
    int j = i + 2;
    while (j < end && lines[j].trim().isNotEmpty && lines[j].contains('|')) {
      final List<String> cells = _splitTableRow(lines[j]);
      final List<List<WbMdInline>> row = <List<WbMdInline>>[];
      for (int c = 0; c < header.length; c++) {
        row.add(c < cells.length ? parseInline(cells[c].trim()) : <WbMdInline>[]);
      }
      rows.add(row);
      j++;
    }
    blocks.add(WbMdTableBlock(header: header, rows: rows, aligns: aligns));
    return j;
  }

  /// 按未转义 `|` 拆分行（首尾空段剔除）。
  static List<String> _splitTableRow(String line) {
    String value = line.trim();
    if (value.startsWith('|')) {
      value = value.substring(1);
    }
    if (value.endsWith('|')) {
      value = value.substring(0, value.length - 1);
    }
    final List<String> cells = <String>[];
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < value.length; i++) {
      final String ch = value[i];
      if (ch == r'\' && i + 1 < value.length && value[i + 1] == '|') {
        buffer.write('|');
        i++;
        continue;
      }
      if (ch == '|') {
        cells.add(buffer.toString());
        buffer.clear();
        continue;
      }
      buffer.write(ch);
    }
    cells.add(buffer.toString());
    return cells;
  }

  /// 列表：收集连续列表行（含懒续行 / 空白容错），构建缩进树。
  static int _parseList(
    List<String> lines,
    int i,
    int end,
    List<WbMdBlock> blocks,
  ) {
    final List<_ListItemDraft> drafts = <_ListItemDraft>[];
    int j = i;
    while (j < end) {
      final String line = lines[j];
      if (line.trim().isEmpty) {
        int k = j + 1;
        while (k < end && lines[k].trim().isEmpty) {
          k++;
        }
        if (k < end && _listRe.hasMatch(lines[k])) {
          j = k;
          continue;
        }
        break;
      }
      final RegExpMatch? match = _listRe.firstMatch(line);
      if (match != null) {
        drafts.add(_ListItemDraft(
          indent: match.group(1)!.replaceAll('\t', '  ').length,
          number: match.group(2),
          ordered: match.group(2) != null,
          content: match.group(4)!,
        ));
        j++;
        continue;
      }
      if (drafts.isNotEmpty &&
          (line.startsWith('  ') || line.startsWith('\t'))) {
        drafts.last.content = '${drafts.last.content}\n${line.trim()}';
        j++;
        continue;
      }
      break;
    }
    if (drafts.isNotEmpty) {
      // 绝对缩进 → 相对层级：首项归 0；后续项在原缩进基础上
      // 最多比前一项深 1 级（避免 `\t` 等造成层级跳跃）。
      for (int d = 0; d < drafts.length; d++) {
        drafts[d].level = drafts[d].indent ~/ 2;
      }
      drafts[0].level = 0;
      for (int d = 1; d < drafts.length; d++) {
        if (drafts[d].level > drafts[d - 1].level + 1) {
          drafts[d].level = drafts[d - 1].level + 1;
        }
      }
      blocks.add(_buildList(drafts));
    }
    return j;
  }

  /// 由扁平草案递归构建列表树。
  static WbMdListBlock _buildList(List<_ListItemDraft> drafts) {
    int cursor = 0;
    WbMdListBlock buildLevel(int level) {
      final List<WbMdListItem> items = <WbMdListItem>[];
      bool ordered = false;
      int start = 1;
      bool first = true;
      while (cursor < drafts.length) {
        final _ListItemDraft draft = drafts[cursor];
        if (draft.level != level) {
          break;
        }
        if (first) {
          ordered = draft.ordered;
          start = int.tryParse(draft.number ?? '') ?? 1;
          first = false;
        }
        cursor++;
        WbMdListBlock? children;
        if (cursor < drafts.length && drafts[cursor].level > level) {
          children = buildLevel(drafts[cursor].level);
        }
        items.add(_buildItem(draft, children));
      }
      return WbMdListBlock(ordered: ordered, start: start, items: items);
    }

    return buildLevel(0);
  }

  static WbMdListItem _buildItem(_ListItemDraft draft, WbMdListBlock? children) {
    String content = draft.content;
    bool? checked;
    final RegExpMatch? task =
        RegExp(r'^\[([ xX])\]\s+(.*)$').firstMatch(content);
    if (task != null) {
      checked = task.group(1)!.toLowerCase() == 'x';
      content = task.group(2)!;
    }
    return WbMdListItem(
      inlines: parseInline(content),
      checked: checked,
      children: children,
    );
  }

  /// 段落：连续非空且非新块起始的行合并（`\n` 保留为软换行）。
  static int _parseParagraph(
    List<String> lines,
    int i,
    int end,
    List<WbMdBlock> blocks,
  ) {
    final StringBuffer buffer = StringBuffer();
    int j = i;
    while (j < end) {
      final String line = lines[j];
      if (line.trim().isEmpty) {
        break;
      }
      if (j > i && _startsNewBlock(lines, j, end)) {
        break;
      }
      if (buffer.isNotEmpty) {
        buffer.write('\n');
      }
      buffer.write(line.trim());
      j++;
    }
    blocks.add(WbMdParagraph(inlines: parseInline(buffer.toString())));
    return j;
  }

  /// 行是否开启新块（供段落终止判断；表格需两行判定）。
  static bool _startsNewBlock(List<String> lines, int index, int end) {
    final String line = lines[index];
    if (_fenceRe.hasMatch(line) ||
        _isMathFence(line) ||
        _headingRe.hasMatch(line) ||
        _dividerRe.hasMatch(line) ||
        _quoteRe.hasMatch(line) ||
        _listRe.hasMatch(line)) {
      return true;
    }
    if (line.contains('|') && _isTableSeparator(lines, index + 1, end)) {
      return true;
    }
    // 当前行是上一行的表格分隔（说明上一行开启了表格）。
    return false;
  }

  /// 去掉标题行尾的 `###` 收尾符。
  static String _stripTrailingHashes(String text) =>
      text.replaceFirst(RegExp(r'\s*#+\s*$'), '').trimRight();

  // ---- 行内解析 -----------------------------------------------------------

  /// 解析行内序列（粗体 / 斜体 / 删除线 / 行内代码 / 链接 / 图片 /
  /// 行内公式；`\` 转义）。
  static List<WbMdInline> parseInline(String text) {
    final List<WbMdInline> out = <WbMdInline>[];
    final StringBuffer buffer = StringBuffer();
    bool bold = false;
    bool italic = false;
    bool strike = false;

    void flush() {
      if (buffer.isEmpty) {
        return;
      }
      out.add(WbMdText(
        text: buffer.toString(),
        bold: bold,
        italic: italic,
        strike: strike,
      ));
      buffer.clear();
    }

    int i = 0;
    while (i < text.length) {
      final String ch = text[i];
      // 转义。
      if (ch == r'\' && i + 1 < text.length) {
        buffer.write(text[i + 1]);
        i += 2;
        continue;
      }
      // 行内代码。
      if (ch == '`') {
        final int close = text.indexOf('`', i + 1);
        if (close > i) {
          flush();
          out.add(WbMdText(text: text.substring(i + 1, close), code: true));
          i = close + 1;
          continue;
        }
      }
      // 图片。
      if (ch == '!' && i + 1 < text.length && text[i + 1] == '[') {
        final int closeBracket = _findCloseBracket(text, i + 1);
        if (closeBracket > 0 &&
            closeBracket + 1 < text.length &&
            text[closeBracket + 1] == '(') {
          final int closeParen = text.indexOf(')', closeBracket + 2);
          if (closeParen > 0) {
            flush();
            out.add(WbMdImage(
              alt: text.substring(i + 2, closeBracket),
              url: text.substring(closeBracket + 2, closeParen),
            ));
            i = closeParen + 1;
            continue;
          }
        }
      }
      // 链接。
      if (ch == '[') {
        final int closeBracket = _findCloseBracket(text, i);
        if (closeBracket > 0 &&
            closeBracket + 1 < text.length &&
            text[closeBracket + 1] == '(') {
          final int closeParen = text.indexOf(')', closeBracket + 2);
          if (closeParen > 0) {
            flush();
            final String label = text.substring(i + 1, closeBracket);
            final String url = text.substring(closeBracket + 2, closeParen);
            for (final WbMdInline inline in parseInline(label)) {
              if (inline is WbMdText) {
                out.add(WbMdText(
                  text: inline.text,
                  bold: inline.bold,
                  italic: inline.italic,
                  strike: inline.strike,
                  code: inline.code,
                  link: url,
                ));
              } else {
                out.add(inline);
              }
            }
            i = closeParen + 1;
            continue;
          }
        }
      }
      // 行内公式。
      if (ch == r'$') {
        final int close = text.indexOf(r'$', i + 1);
        if (close > i + 1) {
          flush();
          out.add(WbMdInlineMath(latex: text.substring(i + 1, close)));
          i = close + 1;
          continue;
        }
      }
      // 粗体（** / __）。
      if ((ch == '*' || ch == '_') &&
          i + 1 < text.length &&
          text[i + 1] == ch) {
        flush();
        bold = !bold;
        i += 2;
        continue;
      }
      // 删除线（~~）。
      if (ch == '~' && i + 1 < text.length && text[i + 1] == '~') {
        flush();
        strike = !strike;
        i += 2;
        continue;
      }
      // 斜体（* / _）。
      if (ch == '*' || ch == '_') {
        flush();
        italic = !italic;
        i += 1;
        continue;
      }
      buffer.write(ch);
      i++;
    }
    flush();
    return out;
  }

  /// 找到与 [openIndex] 处 `[` 匹配的 `]`（支持嵌套；未闭合返回 -1）。
  static int _findCloseBracket(String text, int openIndex) {
    int depth = 0;
    for (int i = openIndex; i < text.length; i++) {
      final String ch = text[i];
      if (ch == r'\') {
        i++;
        continue;
      }
      if (ch == '[') {
        depth++;
      } else if (ch == ']') {
        depth--;
        if (depth == 0) {
          return i;
        }
      }
    }
    return -1;
  }
}

/// 列表项中间草案（缩进 / 标记 / 内容）。
class _ListItemDraft {
  _ListItemDraft({
    required this.indent,
    required this.content,
    required this.ordered,
    this.number,
  });

  final int indent;
  String content;
  final bool ordered;
  final String? number;
  int level = 0;
}
