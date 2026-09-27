/// 帮助中心：快速上手 / 用户手册 / 进阶技巧 / FAQ 与全局搜索
/// （《用户手册与帮助文档设计》§4-§7、§9 内置帮助）。
///
/// - [WbHelpCenter] 为自包含面板组件，不依赖 Provider 与路由，
///   可直接嵌入页面或对话框；
/// - [showHelpCenter] 为模态弹层入口（自包含）；
/// - 分节内容数据来自 [WbGuideContent]，搜索跨全部条目。
library;

import 'package:flutter/material.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

import 'guide_content.dart';
import 'guide_icons.dart';
import 'shortcut_card.dart';

/// 以模态弹层展示帮助中心（自包含，不依赖路由）。
///
/// [initialSection] 指定初始分节；弹层内可切换分节、搜索、查看 FAQ。
Future<void> showHelpCenter(
  BuildContext context, {
  WbGuideSection initialSection = WbGuideSection.quickStart,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭帮助中心',
    barrierColor: const Color(0x66000000),
    transitionDuration: const Duration(milliseconds: 160),
    transitionBuilder: (
      BuildContext ctx,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
    ) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        child: child,
      );
    },
    pageBuilder: (
      BuildContext ctx,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
    ) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 940, maxHeight: 640),
            child: WbHelpCenter(
              initialSection: initialSection,
              onClose: () => Navigator.of(ctx).pop(),
            ),
          ),
        ),
      );
    },
  );
}

/// 帮助中心面板（分节导航 + 内容区 + 搜索）。
class WbHelpCenter extends StatefulWidget {
  const WbHelpCenter({
    super.key,
    this.initialSection = WbGuideSection.quickStart,
    this.onClose,
  });

  /// 初始分节。
  final WbGuideSection initialSection;

  /// 关闭请求（为空时尝试 `Navigator.maybePop`）。
  final VoidCallback? onClose;

  @override
  State<WbHelpCenter> createState() => _WbHelpCenterState();
}

class _WbHelpCenterState extends State<WbHelpCenter> {
  late WbGuideSection _section = widget.initialSection;
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String get _trimmedQuery => _query.text.trim();

  void _selectSection(WbGuideSection section) {
    setState(() {
      _section = section;
      _query.clear();
    });
  }

  void _close() {
    final VoidCallback? onClose = widget.onClose;
    if (onClose != null) {
      onClose();
      return;
    }
    Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final String query = _trimmedQuery;
    return Material(
      color: colors.elevated,
      borderRadius: BorderRadius.circular(12),
      elevation: 10,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: <Widget>[
            _buildHeader(colors),
            Divider(height: 1, color: colors.border),
            _buildSearch(colors),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: Row(
                children: <Widget>[
                  _buildNav(colors),
                  Container(width: 1, color: colors.border),
                  Expanded(
                    child: query.isEmpty
                        ? _buildSectionBody()
                        : _buildSearchBody(query),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(WbThemeColors colors) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: <Widget>[
          Icon(LinearIcons.info, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Text(
            '帮助中心',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '离线可用',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 10,
              color: colors.icon,
            ),
          ),
          const Spacer(),
          SizedBox(
            width: 30,
            height: 30,
            child: IconButton(
              key: const ValueKey<String>('wb-guide-help-close'),
              padding: EdgeInsets.zero,
              iconSize: 16,
              tooltip: '关闭帮助中心',
              onPressed: _close,
              icon: Icon(LinearIcons.close, color: colors.icon),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearch(WbThemeColors colors) {
    final ThemeData theme = Theme.of(context);
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: colors.border),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: TextField(
        key: const ValueKey<String>('wb-guide-help-search'),
        controller: _query,
        onChanged: (String value) => setState(() {}),
        style: theme.textTheme.bodySmall,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索帮助：圆盘、便签、AI、导出…',
          hintStyle: theme.textTheme.bodySmall?.copyWith(color: colors.icon),
          prefixIcon: Icon(LinearIcons.search, size: 16, color: colors.icon),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 36, minHeight: 36),
          contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          border: border,
          focusedBorder: border.copyWith(
            borderSide: BorderSide(color: colors.primary),
          ),
        ),
      ),
    );
  }

  Widget _buildNav(WbThemeColors colors) {
    final String query = _trimmedQuery;
    return Container(
      width: 200,
      color: colors.sidebarBackground,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: <Widget>[
          for (final WbGuideSection section in WbGuideSection.values)
            _NavItem(
              section: section,
              selected: section == _section && query.isEmpty,
              onTap: () => _selectSection(section),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionBody() {
    final Widget content = switch (_section) {
      WbGuideSection.quickStart => const _QuickStartBody(),
      WbGuideSection.manual => const _ManualBody(),
      WbGuideSection.advanced => const _AdvancedBody(),
      WbGuideSection.faq => const _FaqBody(),
    };
    return SingleChildScrollView(
      key: ValueKey<String>('wb-guide-section-${_section.id}'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: content,
    );
  }

  Widget _buildSearchBody(String query) {
    final List<WbGuideSearchHit> hits = WbGuideContent.search(query);
    if (hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '未找到「$query」相关内容\n试试「圆盘」「便签」「导出」等关键词。',
            key: const ValueKey<String>('wb-guide-search-empty'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey<String>('wb-guide-search-results'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: hits.length,
      itemBuilder: (BuildContext context, int index) {
        final WbGuideSearchHit hit = hits[index];
        return _SearchHitRow(
          index: index,
          hit: hit,
          onTap: () => _selectSection(hit.section),
        );
      },
    );
  }
}

/// 分节导航项。
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final WbGuideSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return InkWell(
      key: ValueKey<String>('wb-guide-nav-${section.id}'),
      onTap: onTap,
      child: Container(
        color: selected ? colors.primary.withValues(alpha: 0.10) : null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: <Widget>[
            Icon(
              wbGuideIcon(section.icon),
              size: 16,
              color: selected ? colors.primary : colors.icon,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    section.title,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w600 : null,
                      color: selected ? colors.primary : null,
                    ),
                  ),
                  Text(
                    section.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 10,
                      color: colors.icon,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 搜索结果行（点击跳转所属分节）。
class _SearchHitRow extends StatelessWidget {
  const _SearchHitRow({
    required this.index,
    required this.hit,
    required this.onTap,
  });

  final int index;
  final WbGuideSearchHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return InkWell(
      key: ValueKey<String>('wb-guide-search-hit-$index'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                hit.section.title,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  color: colors.primary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    hit.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    hit.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: colors.icon,
                    ),
                  ),
                ],
              ),
            ),
            Icon(LinearIcons.forward, size: 14, color: colors.icon),
          ],
        ),
      ),
    );
  }
}

/// 分节标题（图标 + 标题 + 一句话说明）。
class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final String icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(wbGuideIcon(icon), size: 16, color: colors.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: colors.icon,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 快速上手分节（§4.1 + §4.2）。
class _QuickStartBody extends StatelessWidget {
  const _QuickStartBody();

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _SectionHeading(
          icon: 'board',
          title: '5 分钟上手白板',
          subtitle: '按顺序完成下面 8 步，即可掌握基本操作。',
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < WbGuideContent.quickStart.length; i++)
          _NumberedRow(index: i + 1, step: WbGuideContent.quickStart[i]),
        const SizedBox(height: 16),
        const _SectionHeading(
          icon: 'pen',
          title: '常用操作',
          subtitle: '10 个高频操作与对应键位。',
        ),
        const SizedBox(height: 8),
        for (final WbGuideShortcut op in WbGuideContent.commonOperations)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    op.label,
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                ),
                WbShortcutKeys(keys: op.resolvedKeys, compact: true),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colors.canvas,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.border),
          ),
          child: Text(
            '提示：随时按 F1 或点击帮助入口重新打开本面板；'
            '快捷键卡片见「进阶技巧」或引导完成页。',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              color: colors.icon,
            ),
          ),
        ),
      ],
    );
  }
}

/// 快速上手编号行。
class _NumberedRow extends StatelessWidget {
  const _NumberedRow({ required this.index, required this.step});

  final int index;
  final WbQuickStartStep step;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11,
                color: colors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  step.title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  step.detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: colors.icon,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 用户手册分节（§5.1 章节树）。
class _ManualBody extends StatelessWidget {
  const _ManualBody();

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _SectionHeading(
          icon: 'page',
          title: '用户手册',
          subtitle: '按章节浏览功能说明；点击章节展开条目。',
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < WbGuideContent.manualChapters.length; i++)
          _ExpandableTile(
            key: ValueKey<String>('wb-guide-manual-$i'),
            title: WbGuideContent.manualChapters[i].title,
            trailingText: '${WbGuideContent.manualChapters[i].topics.length} 条',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final WbManualTopic topic
                    in WbGuideContent.manualChapters[i].topics)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          topic.title,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          topic.summary,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            color: colors.icon,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 进阶技巧分节（§6）。
class _AdvancedBody extends StatelessWidget {
  const _AdvancedBody();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _SectionHeading(
          icon: 'light',
          title: '效率技巧',
          subtitle: '让常用操作更快一步。',
        ),
        const SizedBox(height: 8),
        for (final WbTipEntry tip in WbGuideContent.efficiencyTips)
          _TipRow(entry: tip),
        const SizedBox(height: 16),
        const _SectionHeading(
          icon: 'cube',
          title: '高级功能',
          subtitle: '值得深入的功能。',
        ),
        const SizedBox(height: 8),
        for (final WbTipEntry tip in WbGuideContent.advancedFeatures)
          _TipRow(entry: tip),
        const SizedBox(height: 16),
        const _SectionHeading(
          icon: 'share',
          title: '集成',
          subtitle: '把白板接入你的工具链。',
        ),
        const SizedBox(height: 8),
        for (final WbTipEntry tip in WbGuideContent.integrations)
          _TipRow(entry: tip),
      ],
    );
  }
}

/// 「名称 + 说明」行。
class _TipRow extends StatelessWidget {
  const _TipRow({ required this.entry});

  final WbTipEntry entry;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.name,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  entry.detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: colors.icon,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// FAQ 分节（§7.1 常见问题 + §7.2 故障排查 + §7.3 反馈）。
class _FaqBody extends StatelessWidget {
  const _FaqBody();

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _SectionHeading(
          icon: 'info',
          title: '常见问题',
          subtitle: '点击问题展开答案。',
        ),
        const SizedBox(height: 12),
        for (final WbFaqEntry entry in WbGuideContent.faq)
          _ExpandableTile(
            key: ValueKey<String>('wb-guide-faq-${entry.id}'),
            title: entry.question,
            trailingText: entry.category,
            child: Text(
              entry.answer,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11,
                color: colors.icon,
              ),
            ),
          ),
        const SizedBox(height: 14),
        const _SectionHeading(
          icon: 'warning',
          title: '故障排查',
          subtitle: '按步骤自查，多数问题可自助解决。',
        ),
        const SizedBox(height: 12),
        for (final WbFaqEntry entry in WbGuideContent.troubleshooting)
          _ExpandableTile(
            key: ValueKey<String>('wb-guide-trouble-${entry.id}'),
            title: entry.question,
            trailingText: entry.category,
            child: Text(
              entry.answer,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 11,
                color: colors.icon,
              ),
            ),
          ),
        const SizedBox(height: 14),
        const _SectionHeading(
          icon: 'comment',
          title: '反馈',
          subtitle: '把问题告诉我们，帮助改进产品。',
        ),
        const SizedBox(height: 10),
        const _InfoBlock(title: '反馈渠道', entries: WbGuideContent.feedbackChannels),
        const SizedBox(height: 8),
        const _InfoBlock(title: '反馈内容', entries: WbGuideContent.feedbackChecklist),
        const SizedBox(height: 8),
        const _InfoBlock(
          title: '响应时间',
          entries: WbGuideContent.feedbackResponseTimes,
        ),
      ],
    );
  }
}

/// 信息块（标题 + 若干「名称：说明」条目）。
class _InfoBlock extends StatelessWidget {
  const _InfoBlock({ required this.title, required this.entries});

  final String title;
  final List<WbTipEntry> entries;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          for (final WbTipEntry entry in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 84,
                    child: Text(
                      entry.name,
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entry.detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: colors.icon,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 可展开条目（手册章节 / FAQ 问题），点击标题行切换。
class _ExpandableTile extends StatefulWidget {
  const _ExpandableTile({
    super.key,
    required this.title,
    required this.child,
    this.trailingText = '',
  });

  final String title;
  final String trailingText;
  final Widget child;

  @override
  State<_ExpandableTile> createState() => _ExpandableTileState();
}

class _ExpandableTileState extends State<_ExpandableTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: colors.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.cardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (widget.trailingText.isNotEmpty)
                    Text(
                      widget.trailingText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 10,
                        color: colors.icon,
                      ),
                    ),
                  const SizedBox(width: 6),
                  Icon(
                    _expanded
                        ? LinearIcons.bringForward
                        : LinearIcons.sendBackward,
                    size: 16,
                    color: colors.icon,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: SizedBox(width: double.infinity, child: widget.child),
            ),
        ],
      ),
    );
  }
}
