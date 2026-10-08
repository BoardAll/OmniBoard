/// Markdown 文档 AST（GFM 子集）：块级节点 + 行内节点。
///
/// 方案 §4：Math 与 Mermaid 必须作为独立节点（[WbMdMathBlock] /
/// [WbMdMermaidBlock]），渲染层保持独立图表 / 公式渲染器。
library;

/// 文档根（块序列）。
class WbMdDocument {
  /// 创建文档。
  const WbMdDocument({required this.blocks});

  /// 顶层块序列（按源文顺序）。
  final List<WbMdBlock> blocks;

  /// 是否没有可见内容（空文档 / 全空白）。
  bool get isEmpty => blocks.isEmpty;
}

/// 块级节点基类。
sealed class WbMdBlock {
  /// 创建块。
  const WbMdBlock();
}

/// 标题（`#` ~ `######`）。
class WbMdHeading extends WbMdBlock {
  /// 创建标题。
  const WbMdHeading({required this.level, required this.inlines});

  /// 级别（1..6）。
  final int level;

  /// 行内内容。
  final List<WbMdInline> inlines;
}

/// 段落（普通文本块）。
class WbMdParagraph extends WbMdBlock {
  /// 创建段落。
  const WbMdParagraph({required this.inlines});

  /// 行内内容。
  final List<WbMdInline> inlines;
}

/// 围栏代码块（```lang）。
class WbMdCodeBlock extends WbMdBlock {
  /// 创建代码块。
  const WbMdCodeBlock({required this.language, required this.code});

  /// 语言标识（可空串）。
  final String language;

  /// 代码内容（保留换行）。
  final String code;
}

/// 块级公式（`$$...$$`）。
class WbMdMathBlock extends WbMdBlock {
  /// 创建公式块。
  const WbMdMathBlock({required this.latex});

  /// LaTeX 源（去首尾空白）。
  final String latex;
}

/// Mermaid 图表块（```mermaid 围栏）。
class WbMdMermaidBlock extends WbMdBlock {
  /// 创建图表块。
  const WbMdMermaidBlock({required this.code});

  /// Mermaid 源。
  final String code;
}

/// 引用块（`>`）：内部为递归块序列。
class WbMdQuote extends WbMdBlock {
  /// 创建引用。
  const WbMdQuote({required this.blocks});

  /// 内部块。
  final List<WbMdBlock> blocks;
}

/// 列表块（有序 / 无序 / 任务列表）。
class WbMdListBlock extends WbMdBlock {
  /// 创建列表。
  const WbMdListBlock({
    required this.ordered,
    this.start = 1,
    required this.items,
  });

  /// 是否有序列表。
  final bool ordered;

  /// 有序列表起始序号（无序列表恒为 1）。
  final int start;

  /// 列表项。
  final List<WbMdListItem> items;
}

/// 列表项（可含子列表）。
class WbMdListItem {
  /// 创建列表项。
  const WbMdListItem({
    required this.inlines,
    this.checked,
    this.children,
  });

  /// 项内容（首行 + 懒续行合并后的行内序列）。
  final List<WbMdInline> inlines;

  /// 任务列表勾选状态（null = 非任务项）。
  final bool? checked;

  /// 子列表（缩进更深的第一层嵌套）。
  final WbMdListBlock? children;
}

/// 表格（第一阶段只读显示，方案 §7）。
class WbMdTableBlock extends WbMdBlock {
  /// 创建表格。
  const WbMdTableBlock({
    required this.header,
    required this.rows,
    required this.aligns,
  });

  /// 表头单元格。
  final List<List<WbMdInline>> header;

  /// 数据行。
  final List<List<List<WbMdInline>>> rows;

  /// 每列对齐（与列数等长）。
  final List<WbMdTableAlign> aligns;

  /// 列数。
  int get columnCount => header.length;
}

/// 表格列对齐。
enum WbMdTableAlign {
  /// 左对齐。
  left,

  /// 居中。
  center,

  /// 右对齐。
  right,
}

/// 分割线（`---` / `***` / `___`）。
class WbMdDivider extends WbMdBlock {
  /// 创建分割线。
  const WbMdDivider();
}

/// 解析容错块：非法结构不抛出，显示提示卡片并保留可编辑性。
class WbMdErrorBlock extends WbMdBlock {
  /// 创建错误块。
  const WbMdErrorBlock({required this.message, this.detail = ''});

  /// 概要信息。
  final String message;

  /// 细节（原源片段）。
  final String detail;
}

/// 行内节点基类。
sealed class WbMdInline {
  /// 创建行内节点。
  const WbMdInline();
}

/// 行内文本（携带样式标记）。
class WbMdText extends WbMdInline {
  /// 创建文本。
  const WbMdText({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.code = false,
    this.link = '',
  });

  /// 文本内容。
  final String text;

  /// 粗体。
  final bool bold;

  /// 斜体。
  final bool italic;

  /// 删除线。
  final bool strike;

  /// 行内代码。
  final bool code;

  /// 链接地址（空串 = 非链接）。
  final String link;

  /// 是否为普通文本（无样式、非链接、非代码）。
  bool get isPlain =>
      !bold && !italic && !strike && !code && link.isEmpty;
}

/// 行内公式（`$...$`）。
class WbMdInlineMath extends WbMdInline {
  /// 创建行内公式。
  const WbMdInlineMath({required this.latex});

  /// LaTeX 源。
  final String latex;
}

/// 行内图片（`![alt](url)`）。
class WbMdImage extends WbMdInline {
  /// 创建图片。
  const WbMdImage({required this.alt, required this.url});

  /// 替代文本。
  final String alt;

  /// 图片地址（画布第一阶段以占位卡片呈现）。
  final String url;
}

/// 行内序列的纯文本（搜索高亮 / 目录 / 测试用）。
String wbMdInlinePlainText(List<WbMdInline> inlines) {
  final StringBuffer buffer = StringBuffer();
  for (final WbMdInline inline in inlines) {
    switch (inline) {
      case WbMdText():
        buffer.write(inline.text);
      case WbMdInlineMath():
        buffer.write(inline.latex);
      case WbMdImage():
        buffer.write(inline.alt);
    }
  }
  return buffer.toString();
}
