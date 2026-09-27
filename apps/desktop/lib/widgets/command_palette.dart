/// 命令面板：模糊搜索、键盘导航与执行（《AI 助手与 MCP 设计》§8.1）。
///
/// - 唤起：`Cmd/Ctrl + K`（面板侧注册硬件键盘处理器调用 [showCommandPalette]）；
/// - 交互：↑/↓ 选择、Enter 执行、Esc 关闭、鼠标点击执行；
/// - 命令来源：静态目录（[WbCommandCatalog.defaults]）+ 现有服务动作
///   （通过 [WbCommand.builtin] 由调用方映射到 ai_service / 路由等）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';

/// 一条命令面板命令。
class WbCommand {
  const WbCommand({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.icon,
    this.keywords = const <String>[],
    this.prompt = '',
    this.builtin = '',
  });

  /// 稳定 id（如 `ai.note.create`），用于「最近使用」与内建动作映射。
  final String id;

  /// 中文标题（列表主文案）。
  final String title;

  /// 辅助说明。
  final String subtitle;

  /// 列表图标。
  final IconData? icon;

  /// 检索关键词（拼音 / 英文别名等）。
  final List<String> keywords;

  /// 执行时填入 AI 输入框的自然语言文本（可空）。
  final String prompt;

  /// 内建动作 id（可空；与 [prompt] 二选一，由宿主映射）。
  final String builtin;

  /// 是否为内建动作（交由宿主执行）。
  bool get isBuiltin => builtin.isNotEmpty;

  @override
  String toString() => 'WbCommand($id, $title)';
}

/// 静态命令目录（§8.1 示例 + 现有服务动作）。
abstract final class WbCommandCatalog {
  /// 清空对话（映射到 `WbAiState.reset`）。
  static const String builtinReset = 'ai.reset';

  /// 打开设置（映射到路由 `/settings`）。
  static const String builtinSettings = 'app.settings';

  /// 打开帮助中心（映射到 `showHelpCenter`）。
  static const String builtinHelpCenter = 'help.center';

  /// 打开新手引导（映射到 `showOnboardingOverlay`）。
  static const String builtinOnboarding = 'help.onboarding';

  /// 打开快捷键卡片（映射到 `showShortcutCard`）。
  static const String builtinShortcuts = 'help.shortcuts';

  /// 语音输入开关（映射到语音视觉模拟）。
  static const String builtinVoice = 'voice.toggle';

  /// 默认命令表。
  static const List<WbCommand> defaults = <WbCommand>[
    WbCommand(
      id: 'ai.note.create',
      title: '创建便签',
      subtitle: '按主题批量生成便签',
      icon: LinearIcons.stickyNote,
      keywords: <String>['note', 'sticky', '便签', '创建', '粘贴'],
      prompt: '创建 5 个黄色便签，主题是用户痛点',
    ),
    WbCommand(
      id: 'ai.flowchart.create',
      title: '画流程图',
      subtitle: '从描述生成流程图',
      icon: LinearIcons.flowchart,
      keywords: <String>['flowchart', '流程', '图'],
      prompt: '画一个流程：用户进入 → 浏览白板 → 导出分享',
    ),
    WbCommand(
      id: 'ai.cube.create',
      title: '生成 3D 长方体',
      subtitle: '在画布上创建 3D 元素',
      icon: LinearIcons.cube,
      keywords: <String>['3d', 'cube', '立体', '长方体'],
      prompt: '生成一个 3D 长方体',
    ),
    WbCommand(
      id: 'ai.summarize',
      title: '总结选中的内容',
      subtitle: '对选区生成摘要',
      icon: LinearIcons.text,
      keywords: <String>['summary', 'summarize', '总结', '摘要'],
      prompt: '总结我选中的内容',
    ),
    WbCommand(
      id: 'ai.cluster',
      title: '按主题分组',
      subtitle: '聚类并移动便签',
      icon: LinearIcons.group,
      keywords: <String>['cluster', 'group', '分组', '聚类'],
      prompt: '帮我把选中的便签按主题分组',
    ),
    WbCommand(
      id: 'ai.mindmap.create',
      title: '生成思维导图',
      subtitle: '把选中内容扩成导图',
      icon: LinearIcons.mindmap,
      keywords: <String>['mindmap', '导图', '思维'],
      prompt: '根据选中的内容生成思维导图',
    ),
    WbCommand(
      id: 'ai.connector.create',
      title: '创建连线',
      subtitle: '为选中元素建立关系',
      icon: LinearIcons.connector,
      keywords: <String>['connector', 'line', '连线', '箭头'],
      prompt: '为选中的元素创建连线',
    ),
    WbCommand(
      id: 'ai.reset',
      title: '清空对话',
      subtitle: '清空 AI 会话消息与执行卡片',
      icon: LinearIcons.refresh,
      keywords: <String>['clear', 'reset', '清空', '重置'],
      builtin: builtinReset,
    ),
    WbCommand(
      id: 'ai.voice',
      title: '语音输入',
      subtitle: '开始 / 停止语音输入（视觉模拟）',
      icon: LinearIcons.mic,
      keywords: <String>['voice', 'speech', '语音', '麦克风'],
      builtin: builtinVoice,
    ),
    WbCommand(
      id: 'app.settings',
      title: '打开设置',
      subtitle: '配置 AI 提供商与主题',
      icon: LinearIcons.settings,
      keywords: <String>['settings', 'preferences', '设置', '配置'],
      builtin: builtinSettings,
    ),
    WbCommand(
      id: 'help.center',
      title: '帮助中心',
      subtitle: '快速上手 / 用户手册 / 进阶技巧 / FAQ',
      icon: LinearIcons.info,
      keywords: <String>['help', 'guide', '帮助', '手册', 'faq'],
      builtin: builtinHelpCenter,
    ),
    WbCommand(
      id: 'help.onboarding',
      title: '新手引导',
      subtitle: '分步了解白板核心操作',
      icon: LinearIcons.comment,
      keywords: <String>['onboarding', 'tour', '引导', '教程'],
      builtin: builtinOnboarding,
    ),
    WbCommand(
      id: 'help.shortcuts',
      title: '快捷键卡片',
      subtitle: '查看全部快捷键与键位',
      icon: LinearIcons.grid,
      keywords: <String>['shortcut', 'keymap', '快捷键', '键位'],
      builtin: builtinShortcuts,
    ),
  ];
}

/// 模糊匹配评分：字符顺序子序列命中；连续命中与词首命中加权。
///
/// [query] 为空返回 0（全命中）；无法按顺序匹配返回 null。
int? wbFuzzyScore(String query, String candidate) {
  final String q = query.trim().toLowerCase();
  if (q.isEmpty) {
    return 0;
  }
  final String c = candidate.toLowerCase();
  if (c.isEmpty) {
    return null;
  }
  int score = 0;
  int qi = 0;
  int streak = 0;
  int lastMatch = -2;
  for (int i = 0; i < c.length && qi < q.length; i++) {
    if (c[i] != q[qi]) {
      continue;
    }
    streak = lastMatch == i - 1 ? streak + 1 : 1;
    score += 2 + streak * 3;
    if (i == 0 || _isWordBoundary(c, i)) {
      score += 6;
    }
    lastMatch = i;
    qi++;
  }
  if (qi < q.length) {
    return null;
  }
  if (c.contains(q)) {
    score += 20;
  }
  // 更短的候选整体更相关（轻微惩罚长度）。
  return score - c.length ~/ 4;
}

/// 命令综合评分（-1 表示不匹配）：标题 / 副标题 / id / 关键词取最高分。
int wbCommandScore(WbCommand command, String query) {
  final String trimmed = query.trim();
  if (trimmed.isEmpty) {
    return 0;
  }
  int best = -1;
  void consider(String candidate, {int bonus = 0}) {
    final int? score = wbFuzzyScore(trimmed, candidate);
    if (score != null && score + bonus > best) {
      best = score + bonus;
    }
  }

  consider(command.title, bonus: 8);
  consider(command.subtitle);
  consider(command.id);
  for (final String keyword in command.keywords) {
    consider(keyword, bonus: 4);
  }
  return best;
}

/// 按模糊评分过滤命令（分数降序；同分保持原有顺序）。
List<WbCommand> filterCommands(List<WbCommand> commands, String query) {
  final String trimmed = query.trim();
  if (trimmed.isEmpty) {
    return List<WbCommand>.of(commands);
  }
  final List<({int index, int score, WbCommand command})> scored =
      <({int index, int score, WbCommand command})>[];
  for (int i = 0; i < commands.length; i++) {
    final int score = wbCommandScore(commands[i], trimmed);
    if (score >= 0) {
      scored.add((index: i, score: score, command: commands[i]));
    }
  }
  scored.sort((({int index, int score, WbCommand command}) a,
      ({int index, int score, WbCommand command}) b) {
    final int byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.index.compareTo(b.index);
  });
  return scored
      .map((({int index, int score, WbCommand command}) entry) => entry.command)
      .toList(growable: false);
}

bool _isWordBoundary(String value, int index) {
  if (index <= 0) {
    return true;
  }
  final int prev = value.codeUnitAt(index - 1);
  return prev == 0x20 ||
      prev == 0x2D || // `-`
      prev == 0x5F || // `_`
      prev == 0x2E || // `.`
      prev == 0x2F; // `/`
}

/// 命令面板条目（分节标题 / 命令行 / 空态行）。
class _PaletteEntry {
  const _PaletteEntry.header(this.label)
      : command = null,
        isEmptyRow = false;

  const _PaletteEntry.command(this.command)
      : label = '',
        isEmptyRow = false;

  const _PaletteEntry.empty()
      : label = '',
        command = null,
        isEmptyRow = true;

  final String label;
  final WbCommand? command;
  final bool isEmptyRow;

  bool get isHeader => command == null && !isEmptyRow;
}

/// 命令面板（可独立使用；配合 [showCommandPalette] 作为模态覆盖层展示）。
class CommandPalette extends StatefulWidget {
  const CommandPalette({
    super.key,
    this.commands = WbCommandCatalog.defaults,
    this.recentIds = const <String>[],
    required this.onCommand,
    this.onDismiss,
    this.hintText = '输入命令或自然语言…',
    this.autofocus = true,
  });

  /// 命令来源（默认静态目录）。
  final List<WbCommand> commands;

  /// 最近使用的命令 id（按新→旧；用于「最近使用」分节）。
  final List<String> recentIds;

  /// 命令被执行时回调（Enter / 点击）。
  final ValueChanged<WbCommand> onCommand;

  /// 关闭请求（Esc）；为空时尝试 `Navigator.pop`。
  final VoidCallback? onDismiss;

  /// 搜索框提示。
  final String hintText;

  /// 是否自动聚焦搜索框。
  final bool autofocus;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'command_palette');
  List<_PaletteEntry> _entries = const <_PaletteEntry>[];
  String _selectedId = '';

  @override
  void initState() {
    super.initState();
    _rebuildEntries();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (!mounted) {
      return false;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final bool primary = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (primary && event.logicalKey == LogicalKeyboardKey.keyK) {
      if (event is KeyDownEvent) {
        _dismiss();
        return true;
      }
      return false;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowDown:
          _moveSelection(1);
          return true;
        case LogicalKeyboardKey.arrowUp:
          _moveSelection(-1);
          return true;
        case LogicalKeyboardKey.escape:
          // 对话框 Escape 由框架 DismissIntent（_ModalScope）处理，避免双重 pop；
          // 独立使用（非对话框）时由本组件自行关闭。
          if (ModalRoute.of<Object?>(context)?.barrierDismissible ?? false) {
            return false;
          }
          _dismiss();
          return true;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
          _executeSelected();
          return true;
        default:
          return false;
      }
    }
    return false;
  }

  void _rebuildEntries() {
    final String query = _query.text.trim();
    final List<_PaletteEntry> entries = <_PaletteEntry>[];
    if (query.isEmpty) {
      final List<WbCommand> recents = <WbCommand>[];
      for (final String id in widget.recentIds) {
        for (final WbCommand command in widget.commands) {
          if (command.id == id && !recents.contains(command)) {
            recents.add(command);
          }
        }
      }
      if (recents.isNotEmpty) {
        entries.add(const _PaletteEntry.header('最近使用'));
        entries.addAll(recents.map(_PaletteEntry.command));
      }
      entries.add(const _PaletteEntry.header('全部命令'));
      for (final WbCommand command in widget.commands) {
        if (!recents.contains(command)) {
          entries.add(_PaletteEntry.command(command));
        }
      }
    } else {
      final List<WbCommand> matched = filterCommands(widget.commands, query);
      if (matched.isEmpty) {
        entries.add(const _PaletteEntry.empty());
      } else {
        entries.addAll(matched.map(_PaletteEntry.command));
      }
    }
    _entries = entries;
    _ensureSelection();
  }

  void _ensureSelection() {
    final int? selectedIndex = _indexOfCommandId(_selectedId);
    if (selectedIndex != null) {
      return;
    }
    for (int i = 0; i < _entries.length; i++) {
      final WbCommand? command = _entries[i].command;
      if (command != null) {
        _selectedId = command.id;
        return;
      }
    }
    _selectedId = '';
  }

  int? _indexOfCommandId(String id) {
    if (id.isEmpty) {
      return null;
    }
    for (int i = 0; i < _entries.length; i++) {
      if (_entries[i].command?.id == id) {
        return i;
      }
    }
    return null;
  }

  void _moveSelection(int delta) {
    final List<int> commandIndexes = <int>[
      for (int i = 0; i < _entries.length; i++)
        if (_entries[i].command != null) i,
    ];
    if (commandIndexes.isEmpty) {
      return;
    }
    final int? currentIndex = _indexOfCommandId(_selectedId);
    final int currentPosition =
        currentIndex == null ? -1 : commandIndexes.indexOf(currentIndex);
    final int nextPosition =
        (currentPosition + delta) % commandIndexes.length;
    final int wrapped =
        nextPosition < 0 ? nextPosition + commandIndexes.length : nextPosition;
    setState(() {
      _selectedId = _entries[commandIndexes[wrapped]].command!.id;
    });
  }

  void _executeSelected() {
    final int? index = _indexOfCommandId(_selectedId);
    if (index == null) {
      return;
    }
    final WbCommand? command = _entries[index].command;
    if (command != null) {
      widget.onCommand(command);
    }
  }

  void _dismiss() {
    final VoidCallback? onDismiss = widget.onDismiss;
    if (onDismiss != null) {
      onDismiss();
      return;
    }
    final NavigatorState? navigator = Navigator.maybeOf(context);
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      return;
    }
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return Material(
      color: colors.elevated,
      borderRadius: BorderRadius.circular(10),
      elevation: 8,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: <Widget>[
                  Icon(LinearIcons.search, size: 18, color: colors.icon),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('command_palette.input'),
                      controller: _query,
                      focusNode: _focus,
                      autofocus: widget.autofocus,
                      onChanged: (String value) {
                        setState(_rebuildEntries);
                      },
                      decoration: InputDecoration(
                        hintText: widget.hintText,
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const _KeyHint(label: 'Esc'),
                ],
              ),
            ),
            Divider(height: 1, color: colors.border),
            if (_entries.isEmpty)
              const SizedBox(height: 0)
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: ListView.builder(
                  key: const Key('command_palette.list'),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  shrinkWrap: true,
                  itemCount: _entries.length,
                  itemBuilder: (BuildContext context, int index) {
                    final _PaletteEntry entry = _entries[index];
                    if (entry.isHeader) {
                      return _SectionHeader(label: entry.label);
                    }
                    if (entry.isEmptyRow) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 18,
                        ),
                        child: Text(
                          '无匹配命令',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: colors.icon),
                        ),
                      );
                    }
                    final WbCommand command = entry.command!;
                    return _CommandRow(
                      command: command,
                      selected: command.id == _selectedId,
                      onTap: () => widget.onCommand(command),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 键盘提示小标签。
class _KeyHint extends StatelessWidget {
  const _KeyHint({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: colors.icon, fontSize: 11),
      ),
    );
  }
}

/// 分节标题（最近使用 / 全部命令）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.icon,
              fontSize: 11,
              letterSpacing: 1,
            ),
      ),
    );
  }
}

/// 命令行（图标 + 标题 + 副标题；选中高亮）。
class _CommandRow extends StatelessWidget {
  const _CommandRow({
    required this.command,
    required this.selected,
    required this.onTap,
  });

  final WbCommand command;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final ThemeData theme = Theme.of(context);
    return InkWell(
      key: Key('command_palette.item.${command.id}'),
      onTap: onTap,
      child: Container(
        color: selected ? colors.primary.withValues(alpha: 0.10) : null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: <Widget>[
            Icon(
              command.icon ?? LinearIcons.ai,
              size: 18,
              color: selected ? colors.primary : colors.icon,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    command.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (command.subtitle.isNotEmpty)
                    Text(
                      command.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colors.icon),
                    ),
                ],
              ),
            ),
            if (command.isBuiltin)
              Icon(LinearIcons.forward, size: 14, color: colors.icon),
          ],
        ),
      ),
    );
  }
}

/// 以模态覆盖层展示命令面板（`Cmd/Ctrl + K` 唤起的目标）。
///
/// 返回的 Future 在面板关闭后完成；[onCommand] 在面板关闭后回调。
Future<void> showCommandPalette(
  BuildContext context, {
  required ValueChanged<WbCommand> onCommand,
  List<WbCommand> commands = WbCommandCatalog.defaults,
  List<String> recentIds = const <String>[],
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭命令面板',
    barrierColor: const Color(0x66000000),
    transitionDuration: const Duration(milliseconds: 140),
    transitionBuilder: (
      BuildContext ctx,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
    ) {
      final Animation<double> curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (
      BuildContext ctx,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
    ) {
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 88, left: 24, right: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 460),
            child: CommandPalette(
              commands: commands,
              recentIds: recentIds,
              onCommand: (WbCommand command) {
                Navigator.of(ctx).pop();
                onCommand(command);
              },
              onDismiss: () => Navigator.of(ctx).pop(),
            ),
          ),
        ),
      );
    },
  );
}
