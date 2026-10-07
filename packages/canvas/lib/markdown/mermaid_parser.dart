/// Mermaid 子集解析器（零依赖自研）：源码 → 图模型。
///
/// 覆盖方案 §16 必须清单的 5 类图：flowchart / classDiagram /
/// sequenceDiagram / stateDiagram-v2 / erDiagram；解析失败不抛出，
/// 返回 [WbMermaidError]（错误卡片：Unable to render diagram /
/// Syntax error at line N，方案 §20）。
library;

/// 图模型基类。
sealed class WbMermaidDiagram {
  /// 创建图模型。
  const WbMermaidDiagram();
}

/// 流程图。
class WbMermaidFlowchart extends WbMermaidDiagram {
  /// 创建流程图。
  const WbMermaidFlowchart({
    required this.direction,
    required this.nodes,
    required this.edges,
    this.subgraphs = const <WbMermaidSubgraph>[],
  });

  /// 方向：TD / TB / BT / LR / RL。
  final String direction;

  /// 节点。
  final List<WbMermaidNode> nodes;

  /// 连线。
  final List<WbMermaidEdge> edges;

  /// 子图（subgraph 分组；声明序）。
  final List<WbMermaidSubgraph> subgraphs;
}

/// 流程图子图分组（subgraph ... end）。
class WbMermaidSubgraph {
  /// 创建子图。
  const WbMermaidSubgraph({
    required this.id,
    required this.title,
    required this.nodeIds,
  });

  /// 子图 id（`subgraph id[title]` 的 id；无 id 语法取标题原文）。
  final String id;

  /// 显示标题。
  final String title;

  /// 直接成员节点 id（声明序，按首次归属去重）。
  final List<String> nodeIds;
}

/// 节点形状。
enum WbMermaidNodeShape {
  /// 矩形。
  rect,

  /// 圆角矩形。
  round,

  /// 体育场形（两端圆）。
  stadium,

  /// 圆形。
  circle,

  /// 菱形（判定）。
  diamond,

  /// 六边形。
  hexagon,

  /// 子程序形（双竖边）。
  subroutine,

  /// 旗形（非对称）。
  asymmetric,
}

/// 流程图节点。
class WbMermaidNode {
  /// 创建节点。
  const WbMermaidNode({
    required this.id,
    required this.label,
    this.shape = WbMermaidNodeShape.rect,
    this.hasExplicitShape = false,
  });

  /// 节点 id。
  final String id;

  /// 显示文本。
  final String label;

  /// 形状。
  final WbMermaidNodeShape shape;

  /// 是否带显式形状（合并声明时优先保留）。
  final bool hasExplicitShape;
}

/// 连线样式。
enum WbMermaidEdgeStyle {
  /// 实线。
  solid,

  /// 虚线。
  dotted,

  /// 加粗线。
  thick,
}

/// 流程图连线。
class WbMermaidEdge {
  /// 创建连线。
  const WbMermaidEdge({
    required this.from,
    required this.to,
    this.label = '',
    this.style = WbMermaidEdgeStyle.solid,
    this.hasArrow = true,
  });

  /// 起点节点 id。
  final String from;

  /// 终点节点 id。
  final String to;

  /// 中间标签。
  final String label;

  /// 线样式。
  final WbMermaidEdgeStyle style;

  /// 是否带箭头。
  final bool hasArrow;
}

/// 类图。
class WbMermaidClassDiagram extends WbMermaidDiagram {
  /// 创建类图。
  const WbMermaidClassDiagram({
    required this.classes,
    required this.relations,
  });

  /// 类。
  final List<WbMermaidClass> classes;

  /// 类间关系。
  final List<WbMermaidClassRelation> relations;
}

/// 类（名称 + 成员行）。
class WbMermaidClass {
  /// 创建类。
  const WbMermaidClass({required this.name, required this.members});

  /// 类名。
  final String name;

  /// 成员（`+String name` / `+makeSound()`）。
  final List<String> members;
}

/// 类关系统一类型。
enum WbMermaidRelationType {
  /// 继承（`<|--`）。
  inheritance,

  /// 组合（`*--`）。
  composition,

  /// 聚合（`o--`）。
  aggregation,

  /// 关联（`-->`）。
  association,

  /// 依赖（`..>`）。
  dependency,

  /// 实现（`..|>`）。
  realization,

  /// 链接（`--`）。
  link,
}

/// 类间关系（marker 保留原始方向，供渲染精确绘制）。
class WbMermaidClassRelation {
  /// 创建关系。
  const WbMermaidClassRelation({
    required this.from,
    required this.to,
    required this.marker,
    this.label = '',
  });

  /// 左侧类名。
  final String from;

  /// 右侧类名。
  final String to;

  /// 原始关系标记（如 `<|--` / `-->`）。
  final String marker;

  /// 关系标签。
  final String label;

  /// 归一类型。
  WbMermaidRelationType get type {
    switch (marker) {
      case '<|--':
      case '--|>':
        return WbMermaidRelationType.inheritance;
      case '*--':
      case '--*':
        return WbMermaidRelationType.composition;
      case 'o--':
      case '--o':
        return WbMermaidRelationType.aggregation;
      case '-->':
      case '<--':
        return WbMermaidRelationType.association;
      case '..>':
      case '<..':
        return WbMermaidRelationType.dependency;
      case '..|>':
      case '<|..':
        return WbMermaidRelationType.realization;
      default:
        return WbMermaidRelationType.link;
    }
  }
}

/// 时序图。
class WbMermaidSequenceDiagram extends WbMermaidDiagram {
  /// 创建时序图。
  const WbMermaidSequenceDiagram({
    required this.participants,
    required this.messages,
  });

  /// 参与者（按声明 / 首现顺序）。
  final List<WbMermaidParticipant> participants;

  /// 消息（含 Note）。
  final List<WbMermaidMessage> messages;
}

/// 时序图参与者。
class WbMermaidParticipant {
  /// 创建参与者。
  const WbMermaidParticipant({
    required this.id,
    required this.label,
    this.isActor = false,
  });

  /// 参与者 id。
  final String id;

  /// 显示名。
  final String label;

  /// 是否为 actor（人形）。
  final bool isActor;
}

/// 消息箭头形态。
enum WbMermaidMessageArrow {
  /// 实心箭头（`->>` / `-->>`）。
  filled,

  /// 开放箭头（`->` / `-->`）。
  open,

  /// 叉号（`-x`）。
  cross,

  /// 开放圆（`-)`）。
  openCircle,
}

/// Note 位置。
enum WbMermaidNotePosition {
  /// 非 Note。
  none,

  /// `Note over`。
  over,

  /// `Note left of`。
  leftOf,

  /// `Note right of`。
  rightOf,
}

/// 时序图消息。
class WbMermaidMessage {
  /// 创建消息。
  const WbMermaidMessage({
    required this.from,
    required this.to,
    required this.text,
    this.dashed = false,
    this.arrow = WbMermaidMessageArrow.filled,
    this.note = WbMermaidNotePosition.none,
  });

  /// 发送方。
  final String from;

  /// 接收方。
  final String to;

  /// 消息文本。
  final String text;

  /// 是否虚线。
  final bool dashed;

  /// 箭头形态。
  final WbMermaidMessageArrow arrow;

  /// Note 位置（非 none 时此行是注解）。
  final WbMermaidNotePosition note;
}

/// 状态图。
class WbMermaidStateDiagram extends WbMermaidDiagram {
  /// 创建状态图。
  const WbMermaidStateDiagram({
    required this.states,
    required this.transitions,
  });

  /// 状态（含 `[*]` 起止伪状态）。
  final List<WbMermaidState> states;

  /// 转换。
  final List<WbMermaidTransition> transitions;
}

/// 状态。
class WbMermaidState {
  /// 创建状态。
  const WbMermaidState({required this.id, required this.label});

  /// 状态 id（`[*]` 表示起止）。
  final String id;

  /// 显示文本。
  final String label;

  /// 是否为起止伪状态。
  bool get isPseudo => id == '[*]';
}

/// 状态转换。
class WbMermaidTransition {
  /// 创建转换。
  const WbMermaidTransition({
    required this.from,
    required this.to,
    this.label = '',
  });

  /// 起点状态 id。
  final String from;

  /// 终点状态 id。
  final String to;

  /// 转换标签。
  final String label;
}

/// ER 图。
class WbMermaidErDiagram extends WbMermaidDiagram {
  /// 创建 ER 图。
  const WbMermaidErDiagram({
    required this.entities,
    required this.relations,
  });

  /// 实体。
  final List<WbMermaidEntity> entities;

  /// 实体间关系。
  final List<WbMermaidErRelation> relations;
}

/// ER 实体。
class WbMermaidEntity {
  /// 创建实体。
  const WbMermaidEntity({required this.name, required this.attributes});

  /// 实体名。
  final String name;

  /// 属性（`type name PK`）。
  final List<String> attributes;
}

/// ER 关系。
class WbMermaidErRelation {
  /// 创建关系。
  const WbMermaidErRelation({
    required this.left,
    required this.right,
    required this.leftCard,
    required this.rightCard,
    this.label = '',
    this.dashed = false,
  });

  /// 左实体名。
  final String left;

  /// 右实体名。
  final String right;

  /// 左侧基数（`||` / `o|` / `}|` / `}o` 等）。
  final String leftCard;

  /// 右侧基数。
  final String rightCard;

  /// 关系标签。
  final String label;

  /// 是否为虚线（`..` 非标识关系）。
  final bool dashed;
}

/// 解析容错结果：非法 Mermaid 源码不抛出，渲染为错误卡片。
class WbMermaidError extends WbMermaidDiagram {
  /// 创建错误。
  const WbMermaidError({
    this.message = 'Unable to render diagram',
    required this.detail,
    this.line = 0,
  });

  /// 概要（固定文案，方案 §20）。
  final String message;

  /// 细节（`Syntax error at line N` 等）。
  final String detail;

  /// 出错行号（1 基；0 = 未知）。
  final int line;
}

/// Mermaid 解析入口（纯函数；不抛异常）。
abstract final class WbMermaidParser {
  /// 解析 Mermaid 源码；未知 / 非法语法返回 [WbMermaidError]。
  static WbMermaidDiagram parse(String code) {
    try {
      final String normalized =
          code.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      final List<String> lines = normalized.split('\n');
      int headerIndex = -1;
      String header = '';
      for (int i = 0; i < lines.length; i++) {
        final String t = lines[i].trim();
        if (t.isEmpty || t.startsWith('%%')) {
          continue;
        }
        headerIndex = i;
        header = t;
        break;
      }
      if (headerIndex < 0) {
        return const WbMermaidError(detail: 'Empty diagram');
      }
      if (header.startsWith('flowchart') || header.startsWith('graph')) {
        return _parseFlowchart(lines, headerIndex, header);
      }
      if (header.startsWith('classDiagram')) {
        return _parseClassDiagram(lines, headerIndex);
      }
      if (header.startsWith('sequenceDiagram')) {
        return _parseSequenceDiagram(lines, headerIndex);
      }
      if (header.startsWith('stateDiagram')) {
        return _parseStateDiagram(lines, headerIndex);
      }
      if (header.startsWith('erDiagram')) {
        return _parseErDiagram(lines, headerIndex);
      }
      return WbMermaidError(
        detail: 'Unsupported diagram type: ${_firstWord(header)}',
        line: headerIndex + 1,
      );
    } catch (error) {
      return WbMermaidError(detail: 'Internal parser error: $error');
    }
  }

  static String _firstWord(String text) {
    final int space = text.indexOf(RegExp(r'\s'));
    return space < 0 ? text : text.substring(0, space);
  }

  static bool _isSkippable(String t) {
    if (t.isEmpty || t.startsWith('%%')) {
      return true;
    }
    const List<String> prefixes = <String>[
      'direction ', 'classDef ', 'class ', 'style ',
      'linkStyle', 'click ', 'loop ', 'alt ', 'else', 'opt ', 'par ',
      'and ', 'rect ', 'activate ', 'deactivate ', 'autonumber',
      'scale ', 'note ', 'acctitle', 'accdescr',
    ];
    for (final String prefix in prefixes) {
      if (t.startsWith(prefix)) {
        return true;
      }
    }
    return t == 'end' || t.startsWith('subgraph');
  }

  // ---- flowchart ----------------------------------------------------------

  static WbMermaidDiagram _parseFlowchart(
    List<String> lines,
    int headerIndex,
    String header,
  ) {
    String direction = 'TD';
    final RegExpMatch? dirMatch =
        RegExp(r'^(?:flowchart|graph)\s+(TD|TB|BT|LR|RL)\b')
            .firstMatch(header);
    if (dirMatch != null) {
      direction = dirMatch.group(1)!;
    } else if (!RegExp(r'^(flowchart|graph)$').hasMatch(header)) {
      return WbMermaidError(
        detail: 'Syntax error at line ${headerIndex + 1}',
        line: headerIndex + 1,
      );
    }
    final Map<String, WbMermaidNode> nodeMap = <String, WbMermaidNode>{};
    final List<WbMermaidNode> nodeOrder = <WbMermaidNode>[];
    final List<WbMermaidEdge> edges = <WbMermaidEdge>[];
    final List<WbMermaidSubgraph> subgraphs = <WbMermaidSubgraph>[];
    final List<int> groupStack = <int>[];
    final Map<String, int> nodeGroup = <String, int>{};

    void addNode(WbMermaidNode node) {
      final WbMermaidNode? existing = nodeMap[node.id];
      if (existing == null) {
        nodeMap[node.id] = node;
        nodeOrder.add(node);
        return;
      }
      if (!existing.hasExplicitShape && node.hasExplicitShape) {
        nodeMap[node.id] = node;
        final int index = nodeOrder.indexOf(existing);
        if (index >= 0) {
          nodeOrder[index] = node;
        }
      }
    }

    // 组内语句提及的未归属节点登记到栈顶子图（首次归属去重）。
    void claimNodes(List<WbMermaidNode> nodes) {
      if (groupStack.isEmpty || groupStack.last < 0) {
        return;
      }
      final int top = groupStack.last;
      for (final WbMermaidNode node in nodes) {
        if (nodeGroup.containsKey(node.id)) {
          continue;
        }
        nodeGroup[node.id] = top;
        subgraphs[top].nodeIds.add(node.id);
      }
    }

    for (int i = headerIndex + 1; i < lines.length; i++) {
      final String t = lines[i].trim();
      final RegExpMatch? sub =
          RegExp(r'^subgraph(?:\s+(.*))?$').firstMatch(t);
      if (sub != null) {
        groupStack.add(_pushSubgraph(subgraphs, (sub.group(1) ?? '').trim()));
        continue;
      }
      if (t == 'end') {
        if (groupStack.isNotEmpty) {
          groupStack.removeLast();
        }
        continue;
      }
      if (_isSkippable(t)) {
        continue;
      }
      final (List<WbMermaidNode>, List<WbMermaidEdge>)? result =
          _parseFlowStatement(t);
      if (result == null) {
        return WbMermaidError(
          detail: 'Syntax error at line ${i + 1}',
          line: i + 1,
        );
      }
      for (final WbMermaidNode node in result.$1) {
        addNode(node);
      }
      claimNodes(result.$1);
      edges.addAll(result.$2);
    }
    return WbMermaidFlowchart(
      direction: direction,
      nodes: nodeOrder,
      edges: edges,
      subgraphs: subgraphs,
    );
  }

  /// 解析 subgraph 头部（`id[title]` / `title`）并追加子图；
  /// 返回其下标（空标题返回 -1，仅作栈占位）。
  static int _pushSubgraph(List<WbMermaidSubgraph> subgraphs, String rest) {
    if (rest.isEmpty) {
      return -1;
    }
    final RegExpMatch? declared =
        RegExp(r'^([^\s\[\]]+)\s*\[(.*)\]\s*$').firstMatch(rest);
    final String id;
    final String title;
    if (declared != null) {
      id = declared.group(1)!;
      title = declared.group(2)!.trim();
    } else {
      id = _unquote(rest);
      title = id;
    }
    subgraphs.add(WbMermaidSubgraph(
      id: id,
      title: title.isEmpty ? id : title,
      nodeIds: <String>[],
    ));
    return subgraphs.length - 1;
  }

  /// 解析一条流程图语句（可含链式连线）；无法解析返回 null。
  static (List<WbMermaidNode>, List<WbMermaidEdge>)? _parseFlowStatement(
    String s,
  ) {
    final List<WbMermaidNode> nodes = <WbMermaidNode>[];
    final List<WbMermaidEdge> edges = <WbMermaidEdge>[];
    final (WbMermaidNode, int)? cursor = _readFlowNode(s, 0);
    if (cursor == null) {
      return null;
    }
    nodes.add(cursor.$1);
    WbMermaidNode previous = cursor.$1;
    int pos = cursor.$2;
    while (true) {
      while (pos < s.length && s[pos] == ' ') {
        pos++;
      }
      if (pos >= s.length) {
        break;
      }
      if (s.startsWith(':::', pos)) {
        // `:::className` 样式引用：跳过。
        pos += 3;
        final Match? cls =
            RegExp(r'[A-Za-z0-9_\-]+').matchAsPrefix(s, pos);
        if (cls != null) {
          pos = cls.end;
        }
        continue;
      }
      final (WbMermaidEdgeStyle, bool, String, int)? arrow =
          _readFlowArrow(s, pos);
      if (arrow == null) {
        return null;
      }
      pos = arrow.$4;
      String label = arrow.$3;
      while (pos < s.length && s[pos] == ' ') {
        pos++;
      }
      if (pos < s.length && s[pos] == '|') {
        final int close = s.indexOf('|', pos + 1);
        if (close < 0) {
          return null;
        }
        label = s.substring(pos + 1, close);
        pos = close + 1;
      }
      while (pos < s.length && s[pos] == ' ') {
        pos++;
      }
      final (WbMermaidNode, int)? target = _readFlowNode(s, pos);
      if (target == null) {
        return null; // 如 `A -->` 尾部缺目标。
      }
      edges.add(WbMermaidEdge(
        from: previous.id,
        to: target.$1.id,
        label: label.trim(),
        style: arrow.$1,
        hasArrow: arrow.$2,
      ));
      nodes.add(target.$1);
      previous = target.$1;
      pos = target.$2;
    }
    return (nodes, edges);
  }

  /// 读节点（id + 可选形状标记）。
  static (WbMermaidNode, int)? _readFlowNode(String s, int pos) {
    final Match? idMatch =
        RegExp(r'[A-Za-z0-9_.\-]+').matchAsPrefix(s, pos);
    if (idMatch == null) {
      return null;
    }
    final String id = idMatch.group(0)!;
    int p = idMatch.end;
    String label = id;
    WbMermaidNodeShape shape = WbMermaidNodeShape.rect;
    bool explicit = false;
    if (p < s.length) {
      final String ch = s[p];
      if (ch == '[') {
        if (p + 1 < s.length && s[p + 1] == '[') {
          final int close = s.indexOf(']]', p + 2);
          if (close < 0) {
            return null;
          }
          label = s.substring(p + 2, close);
          shape = WbMermaidNodeShape.subroutine;
          p = close + 2;
        } else {
          final int close = s.indexOf(']', p + 1);
          if (close < 0) {
            return null;
          }
          label = s.substring(p + 1, close);
          p = close + 1;
        }
        explicit = true;
      } else if (ch == '(') {
        if (p + 1 < s.length && s[p + 1] == '(') {
          final int close = s.indexOf('))', p + 2);
          if (close < 0) {
            return null;
          }
          label = s.substring(p + 2, close);
          shape = WbMermaidNodeShape.circle;
          p = close + 2;
        } else {
          final int close = s.indexOf(')', p + 1);
          if (close < 0) {
            return null;
          }
          String inner = s.substring(p + 1, close);
          if (inner.startsWith('[') && inner.endsWith(']')) {
            inner = inner.substring(1, inner.length - 1);
            shape = WbMermaidNodeShape.stadium;
          } else {
            shape = WbMermaidNodeShape.round;
          }
          label = inner;
          p = close + 1;
        }
        explicit = true;
      } else if (ch == '{') {
        if (p + 1 < s.length && s[p + 1] == '{') {
          final int close = s.indexOf('}}', p + 2);
          if (close < 0) {
            return null;
          }
          label = s.substring(p + 2, close);
          shape = WbMermaidNodeShape.hexagon;
          p = close + 2;
        } else {
          final int close = s.indexOf('}', p + 1);
          if (close < 0) {
            return null;
          }
          label = s.substring(p + 1, close);
          shape = WbMermaidNodeShape.diamond;
          p = close + 1;
        }
        explicit = true;
      } else if (ch == '>') {
        final int close = s.indexOf(']', p + 1);
        if (close < 0) {
          return null;
        }
        label = s.substring(p + 1, close);
        shape = WbMermaidNodeShape.asymmetric;
        p = close + 1;
        explicit = true;
      }
    }
    label = _unquote(label.trim());
    return (
      WbMermaidNode(
        id: id,
        label: label,
        shape: shape,
        hasExplicitShape: explicit,
      ),
      p,
    );
  }

  /// 读连线标记；返回（样式, 带箭头, 中间标签, 新位置）。
  static (WbMermaidEdgeStyle, bool, String, int)? _readFlowArrow(
    String s,
    int pos,
  ) {
    const List<String> dotted = <String>['-.->', '-.-'];
    const List<String> thick = <String>['==>', '==='];
    const List<String> solid = <String>['-->', '---', '--x', '--o', '->'];
    for (final String token in dotted) {
      if (s.startsWith(token, pos)) {
        return (
          WbMermaidEdgeStyle.dotted,
          token == '-.->',
          '',
          pos + token.length,
        );
      }
    }
    for (final String token in thick) {
      if (s.startsWith(token, pos)) {
        return (
          WbMermaidEdgeStyle.thick,
          token == '==>',
          '',
          pos + token.length,
        );
      }
    }
    for (final String token in solid) {
      if (s.startsWith(token, pos)) {
        return (
          WbMermaidEdgeStyle.solid,
          token != '---',
          '',
          pos + token.length,
        );
      }
    }
    // `-- label -->` / `-- label ---` / `A -- B`（无标签链接）。
    if (s.startsWith('--', pos)) {
      final int tail = pos + 2;
      final RegExp tokenRe = RegExp(r'-->|---|-\.->|==>|-.->');
      final RegExpMatch? next = tokenRe.firstMatch(s.substring(tail));
      if (next != null) {
        final String label = s.substring(tail, tail + next.start).trim();
        final String token = next.group(0)!;
        final WbMermaidEdgeStyle style = token == '-.->'
            ? WbMermaidEdgeStyle.dotted
            : token == '==>'
                ? WbMermaidEdgeStyle.thick
                : WbMermaidEdgeStyle.solid;
        return (style, token != '---', label, tail + next.end);
      }
      return (WbMermaidEdgeStyle.solid, false, '', tail);
    }
    return null;
  }

  static String _unquote(String text) {
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      return text.substring(1, text.length - 1);
    }
    return text;
  }

  // ---- classDiagram -------------------------------------------------------

  static WbMermaidDiagram _parseClassDiagram(
    List<String> lines,
    int headerIndex,
  ) {
    final Map<String, List<String>> members =
        <String, List<String>>{};
    final List<WbMermaidClassRelation> relations = <WbMermaidClassRelation>[];
    String? blockClass;
    void touch(String name) => members.putIfAbsent(name, () => <String>[]);

    for (int i = headerIndex + 1; i < lines.length; i++) {
      final String t = lines[i].trim();
      if (t.isEmpty || t.startsWith('%%')) {
        continue;
      }
      if (blockClass != null) {
        if (t == '}') {
          blockClass = null;
          continue;
        }
        members[blockClass]!.add(t);
        continue;
      }
      if (t.startsWith('class ')) {
        final RegExpMatch? nameMatch =
            RegExp(r'^class\s+([A-Za-z0-9_]+)').firstMatch(t);
        if (nameMatch == null) {
          return WbMermaidError(
            detail: 'Syntax error at line ${i + 1}',
            line: i + 1,
          );
        }
        final String name = nameMatch.group(1)!;
        touch(name);
        if (t.contains('{')) {
          final int close = t.indexOf('}');
          if (close > 0) {
            final String inner = t.substring(t.indexOf('{') + 1, close);
            for (final String member in inner.split('\n')) {
              if (member.trim().isNotEmpty) {
                members[name]!.add(member.trim());
              }
            }
          } else {
            blockClass = name;
          }
        }
        continue;
      }
      if (_isSkippable(t) || t == '}') {
        continue;
      }
      final int colon = _topLevelColon(t);
      if (colon > 0 && !_looksLikeRelation(t)) {
        // `Animal : +String name` 成员补写。
        final String name = t.substring(0, colon).trim();
        final String member = t.substring(colon + 1).trim();
        touch(name);
        if (member.isNotEmpty) {
          members[name]!.add(member);
        }
        continue;
      }
      final WbMermaidClassRelation? relation = _parseClassRelation(t);
      if (relation == null) {
        return WbMermaidError(
          detail: 'Syntax error at line ${i + 1}',
          line: i + 1,
        );
      }
      touch(relation.from);
      touch(relation.to);
      relations.add(relation);
    }
    return WbMermaidClassDiagram(
      classes: <WbMermaidClass>[
        for (final MapEntry<String, List<String>> entry in members.entries)
          WbMermaidClass(name: entry.key, members: entry.value),
      ],
      relations: relations,
    );
  }

  static bool _looksLikeRelation(String t) {
    const List<String> markers = <String>[
      '<|--', '--|>', '*--', '--*', 'o--', '--o', '-->', '<--',
      '..>', '<..', '..|>', '<|..', '--', '..',
    ];
    for (final String marker in markers) {
      if (t.contains(marker)) {
        return true;
      }
    }
    return false;
  }

  /// 顶层 `:` 位置（避免命中 `::`）；不存在返回 -1。
  static int _topLevelColon(String t) {
    for (int i = 0; i < t.length; i++) {
      if (t[i] == ':') {
        if (i + 1 < t.length && t[i + 1] == ':') {
          i++;
          continue;
        }
        return i;
      }
    }
    return -1;
  }

  static WbMermaidClassRelation? _parseClassRelation(String t) {
    const List<String> markers = <String>[
      '<|--', '--|>', '..|>', '<|..', '*--', '--*', 'o--', '--o',
      '-->', '<--', '..>', '<..', '--', '..',
    ];
    String? marker;
    int markerAt = -1;
    for (final String candidate in markers) {
      final int at = t.indexOf(candidate);
      if (at < 0) {
        continue;
      }
      if (marker == null || at < markerAt) {
        marker = candidate;
        markerAt = at;
      }
    }
    if (marker == null || markerAt <= 0) {
      return null;
    }
    final String from = _unquote(t.substring(0, markerAt).trim());
    if (from.isEmpty || from.contains(' ')) {
      return null;
    }
    String rest = t.substring(markerAt + marker.length).trim();
    String label = '';
    final int colon = rest.indexOf(':');
    if (colon >= 0) {
      label = rest.substring(colon + 1).trim();
      rest = rest.substring(0, colon).trim();
    }
    final String to = _unquote(_unquote(rest.trim()));
    if (to.isEmpty || to.contains(' ')) {
      return null;
    }
    return WbMermaidClassRelation(
      from: from,
      to: to,
      marker: marker,
      label: label,
    );
  }

  // ---- sequenceDiagram ----------------------------------------------------

  static WbMermaidDiagram _parseSequenceDiagram(
    List<String> lines,
    int headerIndex,
  ) {
    final Map<String, WbMermaidParticipant> participantMap =
        <String, WbMermaidParticipant>{};
    final List<WbMermaidParticipant> participants = <WbMermaidParticipant>[];
    final List<WbMermaidMessage> messages = <WbMermaidMessage>[];

    WbMermaidParticipant touch(String id, {String? label, bool? isActor}) {
      final WbMermaidParticipant existing = participantMap.putIfAbsent(
        id,
        () {
          final WbMermaidParticipant created = WbMermaidParticipant(
            id: id,
            label: label ?? id,
            isActor: isActor ?? false,
          );
          participants.add(created);
          return created;
        },
      );
      return existing;
    }

    final RegExp declareRe = RegExp(
      r'^(participant|actor)\s+([^\s]+)(?:\s+as\s+(.+))?$',
    );
    final RegExp messageRe = RegExp(
      r'^([^\s:]+?)\s*(-{1,2}>>|-{1,2}>|-{1,2}x|-{1,2}\)|-{1,2}-?>>?)\s*([^\s:]+?)\s*:\s*(.*)$',
    );
    final RegExp noteRe = RegExp(
      r'^Note\s+(over|left of|right of)\s+([^:]+?)\s*:\s*(.*)$',
    );
    for (int i = headerIndex + 1; i < lines.length; i++) {
      final String t = lines[i].trim();
      if (_isSkippable(t)) {
        continue;
      }
      final RegExpMatch? declare = declareRe.firstMatch(t);
      if (declare != null) {
        touch(
          declare.group(2)!,
          label: _unquote((declare.group(3) ?? declare.group(2)!).trim()),
          isActor: declare.group(1) == 'actor',
        );
        continue;
      }
      final RegExpMatch? note = noteRe.firstMatch(t);
      if (note != null) {
        final String position = note.group(1)!;
        final String target = note.group(2)!.trim();
        final String text = _unquote(note.group(3)!.trim());
        if (position == 'over') {
          final List<String> ids =
              target.split(',').map((String s) => s.trim()).toList();
          final String from = ids.first;
          final String to = ids.length > 1 ? ids[1] : ids.first;
          touch(from);
          touch(to);
          messages.add(WbMermaidMessage(
            from: from,
            to: to,
            text: text,
            note: WbMermaidNotePosition.over,
          ));
        } else {
          final String id = target.replaceAll(RegExp(r'^(left|right) of\s+'), '');
          touch(id);
          messages.add(WbMermaidMessage(
            from: id,
            to: id,
            text: text,
            note: position == 'left of'
                ? WbMermaidNotePosition.leftOf
                : WbMermaidNotePosition.rightOf,
          ));
        }
        continue;
      }
      final RegExpMatch? message = messageRe.firstMatch(t);
      if (message == null) {
        return WbMermaidError(
          detail: 'Syntax error at line ${i + 1}',
          line: i + 1,
        );
      }
      String from = message.group(1)!;
      String to = message.group(3)!;
      final String arrowToken = message.group(2)!;
      from = _stripActivation(from);
      to = _stripActivation(to);
      touch(from);
      touch(to);
      final bool dashed = arrowToken.startsWith('--');
      WbMermaidMessageArrow arrow = WbMermaidMessageArrow.filled;
      if (arrowToken.endsWith('>>')) {
        arrow = WbMermaidMessageArrow.filled;
      } else if (arrowToken.endsWith('>')) {
        arrow = WbMermaidMessageArrow.open;
      } else if (arrowToken.endsWith('x')) {
        arrow = WbMermaidMessageArrow.cross;
      } else if (arrowToken.endsWith(')')) {
        arrow = WbMermaidMessageArrow.openCircle;
      }
      messages.add(WbMermaidMessage(
        from: from,
        to: to,
        text: _unquote(message.group(4)!.trim()),
        dashed: dashed,
        arrow: arrow,
      ));
    }
    return WbMermaidSequenceDiagram(
      participants: participants,
      messages: messages,
    );
  }

  /// 去除激活标记（`B+` / `B-`）。
  static String _stripActivation(String id) {
    if (id.endsWith('+') || id.endsWith('-')) {
      return id.substring(0, id.length - 1);
    }
    return id;
  }

  // ---- stateDiagram -------------------------------------------------------

  static WbMermaidDiagram _parseStateDiagram(
    List<String> lines,
    int headerIndex,
  ) {
    final Map<String, WbMermaidState> stateMap = <String, WbMermaidState>{};
    final List<WbMermaidState> states = <WbMermaidState>[];
    final List<WbMermaidTransition> transitions = <WbMermaidTransition>[];

    WbMermaidState touch(String id, [String? label]) {
      return stateMap.putIfAbsent(id, () {
        final WbMermaidState created =
            WbMermaidState(id: id, label: label ?? id);
        states.add(created);
        return created;
      });
    }

    int blockDepth = 0;
    for (int i = headerIndex + 1; i < lines.length; i++) {
      final String t = lines[i].trim();
      if (t.isEmpty || t.startsWith('%%')) {
        continue;
      }
      if (t.startsWith('state ')) {
        final RegExpMatch? named =
            RegExp(r'^state\s+"(.*)"\s+as\s+([A-Za-z0-9_]+)\s*\{?$')
                .firstMatch(t);
        if (named != null) {
          touch(named.group(2)!, named.group(1));
          if (t.endsWith('{')) {
            blockDepth++;
          }
          continue;
        }
        final RegExpMatch? plain =
            RegExp(r'^state\s+([A-Za-z0-9_]+)\s*\{?$').firstMatch(t);
        if (plain != null) {
          touch(plain.group(1)!);
          if (t.endsWith('{')) {
            blockDepth++;
          }
          continue;
        }
        // `state X : description` 视作标签。
        final RegExpMatch? described =
            RegExp(r'^state\s+([A-Za-z0-9_]+)\s*:\s*(.*)$').firstMatch(t);
        if (described != null) {
          touch(described.group(1)!, described.group(2)!.trim());
          continue;
        }
        return WbMermaidError(
          detail: 'Syntax error at line ${i + 1}',
          line: i + 1,
        );
      }
      if (t == '}') {
        if (blockDepth > 0) {
          blockDepth--;
        }
        continue;
      }
      if (blockDepth > 0) {
        continue; // 复合状态内部暂不展开。
      }
      if (_isSkippable(t) || t == '--') {
        continue;
      }
      final int arrowAt = t.indexOf('-->');
      if (arrowAt < 0) {
        // `ID : description` 状态描述。
        final int colon = t.indexOf(':');
        if (colon > 0 && !t.contains('-->')) {
          touch(t.substring(0, colon).trim(), t.substring(colon + 1).trim());
          continue;
        }
        return WbMermaidError(
          detail: 'Syntax error at line ${i + 1}',
          line: i + 1,
        );
      }
      final String from = _unquote(t.substring(0, arrowAt).trim());
      String rest = t.substring(arrowAt + 3).trim();
      String label = '';
      final int colon = rest.indexOf(':');
      if (colon >= 0) {
        label = _unquote(rest.substring(colon + 1).trim());
        rest = rest.substring(0, colon).trim();
      }
      final String to = _unquote(rest);
      if (from.isEmpty || to.isEmpty) {
        return WbMermaidError(
          detail: 'Syntax error at line ${i + 1}',
          line: i + 1,
        );
      }
      touch(from);
      touch(to);
      transitions.add(WbMermaidTransition(from: from, to: to, label: label));
    }
    return WbMermaidStateDiagram(states: states, transitions: transitions);
  }

  // ---- erDiagram ----------------------------------------------------------

  static WbMermaidDiagram _parseErDiagram(
    List<String> lines,
    int headerIndex,
  ) {
    final Map<String, List<String>> attributes = <String, List<String>>{};
    final List<String> entityOrder = <String>[];
    final List<WbMermaidErRelation> relations = <WbMermaidErRelation>[];

    void touch(String name) {
      if (!attributes.containsKey(name)) {
        attributes[name] = <String>[];
        entityOrder.add(name);
      }
    }

    String? blockEntity;
    final RegExp entityRe = RegExp(r'^([A-Za-z0-9_]+)\s*\{$');
    final RegExp relationRe = RegExp(
      r'^([A-Za-z0-9_]+)\s+([|}o\{\}]{2})\s*(--|\.\.)\s*([|}o\{\}]{2})\s+([A-Za-z0-9_]+)\s*:\s*(.*)$',
    );
    for (int i = headerIndex + 1; i < lines.length; i++) {
      final String t = lines[i].trim();
      if (t.isEmpty || t.startsWith('%%')) {
        continue;
      }
      if (blockEntity != null) {
        if (t == '}') {
          blockEntity = null;
          continue;
        }
        attributes[blockEntity]!.add(t);
        continue;
      }
      if (t == '}') {
        continue;
      }
      final RegExpMatch? entity = entityRe.firstMatch(t);
      if (entity != null) {
        blockEntity = entity.group(1)!;
        touch(blockEntity);
        continue;
      }
      final RegExpMatch? relation = relationRe.firstMatch(t);
      if (relation != null) {
        touch(relation.group(1)!);
        touch(relation.group(5)!);
        relations.add(WbMermaidErRelation(
          left: relation.group(1)!,
          right: relation.group(5)!,
          leftCard: relation.group(2)!,
          rightCard: relation.group(4)!,
          label: relation.group(6)!.trim(),
          dashed: relation.group(3) == '..',
        ));
        continue;
      }
      return WbMermaidError(
        detail: 'Syntax error at line ${i + 1}',
        line: i + 1,
      );
    }
    return WbMermaidErDiagram(
      entities: <WbMermaidEntity>[
        for (final String name in entityOrder)
          WbMermaidEntity(name: name, attributes: attributes[name]!),
      ],
      relations: relations,
    );
  }
}
