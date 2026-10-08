/// Markdown 主题 token：亮 / 暗两套（对齐 `WbCanvasPalette` 与 `WbThemeColors`）。
///
/// 方案 §21：使用统一 `MarkdownTheme` 管理背景、前景、标题、链接、代码、
/// 边框、引用、表格、公式和图表样式；默认关闭任意 HTML/Script 执行。
library;

import 'package:flutter/painting.dart';

/// Markdown 渲染主题。
class WbMarkdownTheme {
  /// 创建主题。
  const WbMarkdownTheme({
    required this.id,
    required this.background,
    required this.foreground,
    required this.muted,
    required this.primary,
    required this.link,
    required this.border,
    required this.headingBorder,
    required this.codeBackground,
    required this.inlineCodeBackground,
    required this.codeForeground,
    required this.codeBorder,
    required this.codeComment,
    required this.codeKeyword,
    required this.codeString,
    required this.codeNumber,
    required this.quoteBackground,
    required this.quoteBorder,
    required this.tableBorder,
    required this.tableHeaderBackground,
    required this.divider,
    required this.mathForeground,
    required this.diagramStroke,
    required this.diagramFill,
    required this.diagramText,
    required this.diagramAccent,
    required this.imageBackground,
    required this.errorBackground,
    required this.errorBorder,
    required this.errorForeground,
    required this.searchHighlight,
  });

  /// 主题 id（渲染缓存 key 之一：`light` / `dark`）。
  final String id;

  /// 元素背景（卡片底色）。
  final Color background;

  /// 正文前景色。
  final Color foreground;

  /// 次要文本色。
  final Color muted;

  /// 主色（勾选框、强调）。
  final Color primary;

  /// 链接色。
  final Color link;

  /// 卡片描边。
  final Color border;

  /// 标题下边框（h1 / h2）。
  final Color headingBorder;

  /// 代码块背景。
  final Color codeBackground;

  /// 行内代码背景。
  final Color inlineCodeBackground;

  /// 代码文本色。
  final Color codeForeground;

  /// 代码块描边。
  final Color codeBorder;

  /// 语法高亮：注释。
  final Color codeComment;

  /// 语法高亮：关键字。
  final Color codeKeyword;

  /// 语法高亮：字符串。
  final Color codeString;

  /// 语法高亮：数字。
  final Color codeNumber;

  /// 引用块背景。
  final Color quoteBackground;

  /// 引用块竖条。
  final Color quoteBorder;

  /// 表格描边。
  final Color tableBorder;

  /// 表头背景。
  final Color tableHeaderBackground;

  /// 分割线。
  final Color divider;

  /// 公式前景。
  final Color mathForeground;

  /// 图表线 / 描边。
  final Color diagramStroke;

  /// 图表填充。
  final Color diagramFill;

  /// 图表文本。
  final Color diagramText;

  /// 图表强调（箭头、泳道标题）。
  final Color diagramAccent;

  /// 图片 / 占位卡底色。
  final Color imageBackground;

  /// 错误卡片背景。
  final Color errorBackground;

  /// 错误卡片描边。
  final Color errorBorder;

  /// 错误卡片前景。
  final Color errorForeground;

  /// 搜索命中高亮。
  final Color searchHighlight;

  /// 正文字号。
  double get baseFontSize => 14.5;

  /// 正文行高倍数。
  double get lineHeight => 1.55;

  /// 代码字号。
  double get codeFontSize => 13;

  /// 代码行高倍数。
  double get codeLineHeight => 1.45;

  /// 内容内边距。
  double get padding => 18;

  /// 标题字号（按级别）。
  double headingFontSize(int level) {
    switch (level) {
      case 1:
        return 25;
      case 2:
        return 21;
      case 3:
        return 17.5;
      case 4:
        return 15.5;
      case 5:
        return 14.5;
      default:
        return 14.5;
    }
  }

  /// 等宽字体族回退（含 Web CJK 回退）。
  static const List<String> monoFontFallback = <String>[
    'Consolas',
    'Courier New',
    'monospace',
  ];

  /// 亮色主题（对齐 `WbCanvasPalette` 文本 / 主色）。
  static const WbMarkdownTheme light = WbMarkdownTheme(
    id: 'light',
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF1F2933),
    muted: Color(0xFF667085),
    primary: Color(0xFF3370FF),
    link: Color(0xFF3370FF),
    border: Color(0xFFE4E7EC),
    headingBorder: Color(0xFFE9EDF2),
    codeBackground: Color(0xFFF5F6F8),
    inlineCodeBackground: Color(0xFFF0F2F5),
    codeForeground: Color(0xFF1F2933),
    codeBorder: Color(0xFFE4E7EC),
    codeComment: Color(0xFF6E7781),
    codeKeyword: Color(0xFFCF222E),
    codeString: Color(0xFF0A3069),
    codeNumber: Color(0xFF0550AE),
    quoteBackground: Color(0xFFF7F8FA),
    quoteBorder: Color(0xFFD0D5DD),
    tableBorder: Color(0xFFE4E7EC),
    tableHeaderBackground: Color(0xFFF7F8FA),
    divider: Color(0xFFE4E7EC),
    mathForeground: Color(0xFF1F2933),
    diagramStroke: Color(0xFF475467),
    diagramFill: Color(0xFFF7F8FA),
    diagramText: Color(0xFF1F2933),
    diagramAccent: Color(0xFF3370FF),
    imageBackground: Color(0xFFE9EDF2),
    errorBackground: Color(0xFFFFF5F5),
    errorBorder: Color(0xFFF0A8A8),
    errorForeground: Color(0xFFB42318),
    searchHighlight: Color(0x66F5C518),
  );

  /// 暗色主题。
  static const WbMarkdownTheme dark = WbMarkdownTheme(
    id: 'dark',
    background: Color(0xFF1E1F22),
    foreground: Color(0xFFE6E6E6),
    muted: Color(0xFF9AA0A6),
    primary: Color(0xFF5B8DEF),
    link: Color(0xFF6EA8FE),
    border: Color(0xFF3A3C40),
    headingBorder: Color(0xFF3A3C40),
    codeBackground: Color(0xFF2A2C30),
    inlineCodeBackground: Color(0xFF33363B),
    codeForeground: Color(0xFFE6E6E6),
    codeBorder: Color(0xFF3A3C40),
    codeComment: Color(0xFF8B949E),
    codeKeyword: Color(0xFFFF7B72),
    codeString: Color(0xFFA5D6FF),
    codeNumber: Color(0xFF79C0FF),
    quoteBackground: Color(0xFF26282C),
    quoteBorder: Color(0xFF4A4D52),
    tableBorder: Color(0xFF3A3C40),
    tableHeaderBackground: Color(0xFF26282C),
    divider: Color(0xFF3A3C40),
    mathForeground: Color(0xFFE6E6E6),
    diagramStroke: Color(0xFF9AA0A6),
    diagramFill: Color(0xFF26282C),
    diagramText: Color(0xFFE6E6E6),
    diagramAccent: Color(0xFF5B8DEF),
    imageBackground: Color(0xFF2A2C30),
    errorBackground: Color(0xFF3A2426),
    errorBorder: Color(0xFF8A3A3A),
    errorForeground: Color(0xFFF0A8A8),
    searchHighlight: Color(0x66F5C518),
  );

  /// 按 id 解析主题（未知 / null 回退亮色）。
  static WbMarkdownTheme resolve(String? id) =>
      id == 'dark' ? dark : light;
}
