/// 远端在场层：协作光标与选区（M2 D2-B / D2.4 入口渲染）。
///
/// 结构：
/// - [WbRemotePresenceStore]：消费 `onRemotePreviews` 批次中的
///   `cursor` / `selection` 帧（pageId 非当前页丢弃；跨端命名空间经
///   页序后缀近似，见 `preview_page_match.dart`）；按 userId 维护
///   状态、哈希配色、**500ms 缓动插值**（easeOutCubic）、静止 **5s** 淡出、
///   **10s** 超时清理；
/// - [WbRemoteCursorsOverlay]：**独立 Ticker 驱动**（不依赖 controller
///   通知产生动效帧）；坐标经 [WbCanvasController.worldToScreen] 换算，
///   视口变化随控制器通知重算；
/// - 光标短标签（userId 尾 6 位 / 「成员」）；他人选区淡色框线 + 浅填充。
///
/// 宿主（`board_edit_page`）装配：把 `_collab.onRemotePreviews` 批次转交
/// [WbRemotePresenceStore.handlePreviews]，并把 [WbRemoteCursorsOverlay]
/// 以 `Positioned.fill` 叠加在画布之上（IgnorePointer，不拦截交互）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../canvas/canvas_controller.dart';
import '../canvas/canvas_model.dart';
import 'preview_page_match.dart';

/// 单个远端光标状态（位置插值 + 静置淡出）。
class WbRemoteCursorState {
  /// 创建光标状态（初始位置即目标）。
  WbRemoteCursorState({
    required this.userId,
    required this.color,
    required this.interpolationDuration,
    required Offset position,
    required DateTime updatedAt,
  })  : _from = position,
        _to = position,
        _segmentStart = updatedAt,
        lastUpdate = updatedAt;

  /// 远端用户 id（服务端 `presence:preview` 注入；非空）。
  final String userId;

  /// 显示色（按 userId 哈希生成，见 [WbRemotePresenceStore.colorFor]）。
  final Color color;

  /// 单段插值时长（新目标到达后从当前视觉位置缓动到目标）。
  final Duration interpolationDuration;

  /// 最近一次收到更新的时间（淡出 / 清理计时基准）。
  DateTime lastUpdate;

  /// 插值段起点（视觉位置）。
  Offset _from;

  /// 插值段目标（最新收到的世界坐标）。
  Offset _to;

  /// 插值段起始时间。
  DateTime _segmentStart;

  /// 最新目标坐标（测试 / 诊断用）。
  Offset get target => _to;

  /// 当前插值位置（easeOutCubic；t ≥ 1 后停在目标）。
  Offset positionAt(DateTime now) {
    if (_to == _from) {
      return _to;
    }
    final int durationUs = interpolationDuration.inMicroseconds;
    if (durationUs <= 0) {
      return _to;
    }
    final double t = (now.difference(_segmentStart).inMicroseconds / durationUs)
        .clamp(0.0, 1.0);
    if (t >= 1) {
      return _to;
    }
    final double eased = 1 - (1 - t) * (1 - t) * (1 - t);
    return Offset.lerp(_from, _to, eased)!;
  }

  /// 更新目标：从当前视觉位置出发（保持插值连续，不跳跃）。
  void updateTarget(Offset next, DateTime now) {
    lastUpdate = now;
    if (next == _to) {
      return;
    }
    _from = positionAt(now);
    _to = next;
    _segmentStart = now;
  }

  /// 静置淡出透明度（[idleFadeAfter] 后线性淡出 [fadeDuration]）。
  double alphaAt(
    DateTime now, {
    required Duration idleFadeAfter,
    required Duration fadeDuration,
  }) =>
      _fadeAlpha(
        now.difference(lastUpdate),
        idleFadeAfter: idleFadeAfter,
        fadeDuration: fadeDuration,
      );

  /// 是否超过 [cleanupAfter] 无更新（应从 store 移除）。
  bool isExpiredAt(DateTime now, Duration cleanupAfter) =>
      now.difference(lastUpdate) >= cleanupAfter;
}

/// 单个远端选区状态（选中元素 id 集 + 静置淡出）。
class WbRemoteSelectionState {
  /// 创建选区状态。
  WbRemoteSelectionState({
    required this.userId,
    required this.color,
    required List<String> elementIds,
    required DateTime updatedAt,
  })  : elementIds = List<String>.unmodifiable(elementIds),
        lastUpdate = updatedAt;

  /// 远端用户 id（非空）。
  final String userId;

  /// 显示色（与光标同源）。
  final Color color;

  /// 选中的元素 id 集（当前页）。
  List<String> elementIds;

  /// 最近一次收到更新的时间。
  DateTime lastUpdate;

  /// 更新选区（整体替换 id 集）。
  void update(List<String> ids, DateTime now) {
    elementIds = List<String>.unmodifiable(ids);
    lastUpdate = now;
  }

  /// 静置淡出透明度（同光标口径）。
  double alphaAt(
    DateTime now, {
    required Duration idleFadeAfter,
    required Duration fadeDuration,
  }) =>
      _fadeAlpha(
        now.difference(lastUpdate),
        idleFadeAfter: idleFadeAfter,
        fadeDuration: fadeDuration,
      );

  /// 是否超过 [cleanupAfter] 无更新（应从 store 移除）。
  bool isExpiredAt(DateTime now, Duration cleanupAfter) =>
      now.difference(lastUpdate) >= cleanupAfter;
}

/// 在场状态仓库：消费远端 `cursor` / `selection` 预览帧。
///
/// 时钟可注入（测试用假时钟推进插值 / 淡出 / 清理）；动效帧由
/// [WbRemoteCursorsOverlay] 的独立 Ticker 每帧调用 [frameTick] 驱动，
/// 不依赖画布控制器通知。
class WbRemotePresenceStore extends ChangeNotifier {
  /// 创建仓库。
  ///
  /// [clock] 默认 `DateTime.now`（测试注入假时钟）。
  WbRemotePresenceStore({
    DateTime Function()? clock,
    this.interpolationDuration = const Duration(milliseconds: 500),
    this.idleFadeAfter = const Duration(seconds: 5),
    this.fadeDuration = const Duration(seconds: 2),
    this.cleanupAfter = const Duration(seconds: 10),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// 单段插值时长（500ms 缓动）。
  final Duration interpolationDuration;

  /// 静止后开始淡出的延时（5s）。
  final Duration idleFadeAfter;

  /// 淡出时长（2s）。
  final Duration fadeDuration;

  /// 无更新清理时长（10s；晚于淡出结束）。
  final Duration cleanupAfter;

  final Map<String, WbRemoteCursorState> _cursors =
      <String, WbRemoteCursorState>{};
  final Map<String, WbRemoteSelectionState> _selections =
      <String, WbRemoteSelectionState>{};
  String _pageId = '';

  /// 当前跟随的页面 id（宿主经 [syncPage] 推送）。
  String get pageId => _pageId;

  /// 远端光标列表（不可变视图）。
  List<WbRemoteCursorState> get cursors =>
      List<WbRemoteCursorState>.unmodifiable(_cursors.values);

  /// 远端选区列表（不可变视图）。
  List<WbRemoteSelectionState> get selections =>
      List<WbRemoteSelectionState>.unmodifiable(_selections.values);

  /// 是否有需要渲染 / 驱动的条目（Ticker 启停依据）。
  bool get hasEntries => _cursors.isNotEmpty || _selections.isNotEmpty;

  /// 当前时间（绘制 / 测试口径统一）。
  DateTime now() => _clock();

  /// 页面切换：清空非当前页残留（幂等；画布页变化时调用）。
  void syncPage(String pageId) {
    if (pageId == _pageId) {
      return;
    }
    _pageId = pageId;
    if (_cursors.isEmpty && _selections.isEmpty) {
      return;
    }
    _cursors.clear();
    _selections.clear();
    notifyListeners();
  }

  /// 消费远端预览批次（`onRemotePreviews` 转交）。
  ///
  /// [pageId] 为宿主当前页；帧内 pageId 与当前页不符（且非空）丢弃，
  /// 跨端命名空间差异经 `previewPageMatches` 页序后缀近似匹配。
  void handlePreviews(List<dynamic> previews, {required String pageId}) {
    syncPage(pageId);
    final DateTime now = _clock();
    bool changed = false;
    for (final Object? item in previews) {
      final Map<String, dynamic> preview = item is Map<String, dynamic>
          ? item
          : item is Map
              ? Map<String, dynamic>.from(item)
              : const <String, dynamic>{};
      if (preview.isEmpty) {
        continue;
      }
      // 跨端 pageId 命名空间不同：经页序后缀近似匹配放行同页序帧。
      final Object? rawPage = preview['pageId'];
      if (!previewPageMatches(rawPage, _pageId)) {
        continue; // 非当前页：丢弃。
      }
      switch (preview['kind']) {
        case 'cursor':
          changed = _consumeCursor(preview, now) || changed;
        case 'selection':
          changed = _consumeSelection(preview, now) || changed;
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  /// 每帧推进：清理超时条目；返回是否仍有条目（false = Ticker 可停）。
  bool frameTick() {
    final DateTime now = _clock();
    final int before = _cursors.length + _selections.length;
    _cursors.removeWhere(
      (String _, WbRemoteCursorState s) => s.isExpiredAt(now, cleanupAfter),
    );
    _selections.removeWhere(
      (String _, WbRemoteSelectionState s) => s.isExpiredAt(now, cleanupAfter),
    );
    final int after = _cursors.length + _selections.length;
    if (after != before) {
      notifyListeners();
    }
    return after > 0;
  }

  bool _consumeCursor(Map<String, dynamic> preview, DateTime now) {
    final String? userId = _previewString(preview['userId']);
    final double? x = _previewDouble(preview['x']);
    final double? y = _previewDouble(preview['y']);
    if (userId == null || x == null || y == null) {
      return false;
    }
    final WbRemoteCursorState? existing = _cursors[userId];
    if (existing == null) {
      _cursors[userId] = WbRemoteCursorState(
        userId: userId,
        color: colorFor(userId),
        interpolationDuration: interpolationDuration,
        position: Offset(x, y),
        updatedAt: now,
      );
    } else {
      existing.updateTarget(Offset(x, y), now);
    }
    return true;
  }

  bool _consumeSelection(Map<String, dynamic> preview, DateTime now) {
    final String? userId = _previewString(preview['userId']);
    if (userId == null) {
      return false;
    }
    final List<String> ids = _previewStrings(preview['elementIds']);
    if (ids.isEmpty) {
      return _selections.remove(userId) != null;
    }
    final WbRemoteSelectionState? existing = _selections[userId];
    if (existing == null) {
      _selections[userId] = WbRemoteSelectionState(
        userId: userId,
        color: colorFor(userId),
        elementIds: ids,
        updatedAt: now,
      );
    } else {
      existing.update(ids, now);
    }
    return true;
  }

  /// 按 userId 哈希配色（自实现稳定哈希；空 id 返回中性灰）。
  static Color colorFor(String userId) {
    if (userId.isEmpty) {
      return const Color(0xFF6B7280);
    }
    int hash = 17;
    for (final int unit in userId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.62, 0.42).toColor();
  }

  /// 光标 / 标签短文案（userId 尾 6 位；空 id 收敛为「成员」）。
  static String labelFor(String userId) {
    if (userId.isEmpty) {
      return '成员';
    }
    final String tail =
        userId.length <= 6 ? userId : userId.substring(userId.length - 6);
    return '成员 $tail';
  }
}

/// 远端光标 / 选区绘制层。
///
/// `IgnorePointer` + `CustomPaint`：不拦截任何指针事件；独立 Ticker
/// （由 [WbRemotePresenceStore.hasEntries] 启停）每帧推进 [ValueNotifier]
/// 触发重绘，插值 / 淡出与画布控制器通知解耦。
class WbRemoteCursorsOverlay extends StatefulWidget {
  /// 创建覆盖层。
  ///
  /// [controller] 用于世界坐标 → 屏幕坐标换算（视口变化时随其通知重算）。
  const WbRemoteCursorsOverlay({
    super.key,
    required this.store,
    required this.controller,
  });

  /// 在场状态仓库（宿主持有并转交预览批次）。
  final WbRemotePresenceStore store;

  /// 画布控制器（视口换算）。
  final WbCanvasController controller;

  @override
  State<WbRemoteCursorsOverlay> createState() => _WbRemoteCursorsOverlayState();
}

class _WbRemoteCursorsOverlayState extends State<WbRemoteCursorsOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    widget.store.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant WbRemoteCursorsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_syncTicker);
      widget.store.addListener(_syncTicker);
      _syncTicker();
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_syncTicker);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  /// 按条目有无启停 Ticker（无内容时零帧开销）。
  void _syncTicker() {
    if (!mounted) {
      return;
    }
    final bool shouldRun = widget.store.hasEntries;
    if (shouldRun && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    _frame.value++;
    if (!widget.store.frameTick() && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _WbPresencePainter(
          store: widget.store,
          controller: widget.controller,
          frame: _frame,
        ),
      ),
    );
  }
}

/// 在场层绘制器：他人选区框线 + 协作光标（箭头 + 短标签）。
class _WbPresencePainter extends CustomPainter {
  _WbPresencePainter({
    required this.store,
    required this.controller,
    required this.frame,
  }) : super(
          repaint: Listenable.merge(<Listenable>[store, controller, frame]),
        );

  /// 在场状态（每帧读取插值位置 / 透明度）。
  final WbRemotePresenceStore store;

  /// 画布控制器（世界坐标 → 屏幕坐标）。
  final WbCanvasController controller;

  /// 动效帧计数（每 tick 自增，驱动重绘）。
  final ValueNotifier<int> frame;

  /// 光标箭头长度（屏幕像素）。
  static const double _arrowLength = 15;

  @override
  void paint(Canvas canvas, Size size) {
    final DateTime now = store.now();
    _paintSelections(canvas, now);
    _paintCursors(canvas, now);
  }

  /// 他人选区：淡色框线 + 浅填充（元素已被删除 / 不可见时跳过）。
  void _paintSelections(Canvas canvas, DateTime now) {
    for (final WbRemoteSelectionState selection in store.selections) {
      final double alpha = selection.alphaAt(
        now,
        idleFadeAfter: store.idleFadeAfter,
        fadeDuration: store.fadeDuration,
      );
      if (alpha <= 0) {
        continue;
      }
      for (final String elementId in selection.elementIds) {
        final WbCanvasElement? element =
            controller.document.byId(controller.pageId, elementId);
        if (element == null || !element.visible) {
          continue;
        }
        final Rect rect = controller
            .worldRectToScreen(
              Rect.fromLTWH(element.x, element.y, element.width, element.height),
            )
            .inflate(2);
        final RRect rrect =
            RRect.fromRectAndRadius(rect, const Radius.circular(3));
        canvas.drawRRect(
          rrect,
          Paint()..color = _alphaColor(selection.color, 0.10 * alpha),
        );
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = _alphaColor(selection.color, 0.90 * alpha),
        );
      }
    }
  }

  /// 协作光标：白描边箭头 + 用户色填充 + 短标签胶囊。
  void _paintCursors(Canvas canvas, DateTime now) {
    for (final WbRemoteCursorState cursor in store.cursors) {
      final double alpha = cursor.alphaAt(
        now,
        idleFadeAfter: store.idleFadeAfter,
        fadeDuration: store.fadeDuration,
      );
      if (alpha <= 0) {
        continue;
      }
      final Offset origin = controller.worldToScreen(cursor.positionAt(now));
      final Path arrow = Path()
        ..moveTo(origin.dx, origin.dy)
        ..lineTo(origin.dx, origin.dy + _arrowLength)
        ..lineTo(origin.dx + 4.2, origin.dy + 11.2)
        ..lineTo(origin.dx + 6.6, origin.dy + 17.0)
        ..lineTo(origin.dx + 9.0, origin.dy + 16.0)
        ..lineTo(origin.dx + 6.6, origin.dy + 10.3)
        ..lineTo(origin.dx + 12.0, origin.dy + 9.8)
        ..close();
      canvas.drawPath(
        arrow,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round
          ..color = const Color(0xFFFFFFFF).withValues(alpha: alpha),
      );
      canvas.drawPath(arrow, Paint()..color = _alphaColor(cursor.color, alpha));
      _paintCursorLabel(canvas, origin, cursor, alpha);
    }
  }

  /// 光标短标签（右下 14px 偏移处的胶囊）。
  void _paintCursorLabel(
    Canvas canvas,
    Offset origin,
    WbRemoteCursorState cursor,
    double alpha,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: WbRemotePresenceStore.labelFor(cursor.userId),
        style: const TextStyle(
          fontSize: 11,
          height: 1.2,
          color: Color(0xFFFFFFFF),
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    final Rect labelRect = Rect.fromLTWH(
      origin.dx + 14,
      origin.dy + 15,
      painter.width + 12,
      painter.height + 5,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(6)),
      Paint()..color = _alphaColor(cursor.color, 0.95 * alpha),
    );
    painter.paint(canvas, Offset(labelRect.left + 6, labelRect.top + 2.5));
  }

  @override
  bool shouldRepaint(covariant _WbPresencePainter oldDelegate) =>
      oldDelegate.store != store ||
      oldDelegate.controller != controller ||
      oldDelegate.frame != frame;
}

/// 静置淡出透明度：超过 [idleFadeAfter] 后线性降至 0。
double _fadeAlpha(
  Duration idle, {
  required Duration idleFadeAfter,
  required Duration fadeDuration,
}) {
  if (idle <= idleFadeAfter) {
    return 1;
  }
  final int fadeUs = fadeDuration.inMicroseconds;
  if (fadeUs <= 0) {
    return 0;
  }
  final double t =
      (idle.inMicroseconds - idleFadeAfter.inMicroseconds) / fadeUs;
  return (1 - t).clamp(0.0, 1.0);
}

/// 颜色叠加透明度（保留原 alpha 通道比例）。
Color _alphaColor(Color color, double alpha) =>
    color.withValues(alpha: color.a * alpha);

/// 非空字符串（空串 / 非字符串视为缺失）。
String? _previewString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// 数值解析（num / 数字串）。
double? _previewDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

/// 字符串列表解析（丢弃空串 / 非字符串项）。
List<String> _previewStrings(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  final List<String> result = <String>[];
  for (final Object? item in value) {
    if (item is String && item.isNotEmpty) {
      result.add(item);
    }
  }
  return result;
}
