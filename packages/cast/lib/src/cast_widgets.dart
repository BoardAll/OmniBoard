/// 白板内的投屏 UI：投屏码悬浮卡 + 视频浮层容器。
///
/// 隔离原则（与需求对齐）：
/// - 只作为画布上方的 Flutter 覆盖层存在，**不注册为白板 Element**；
/// - 不参与白板文档保存 / 导出 / 普通内容同步 / 撤销重做；
/// - 浮层位置与大小仅存在于当前会话（退出白板即释放）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:whiteboard_theme/theme.dart';

import 'cast_controller.dart';
import 'cast_models.dart';
import 'cast_peer.dart';

/// 投屏码悬浮卡（可拖动 / 折叠 / 复制 / 换码）。
class WbCastCodeOverlay extends StatefulWidget {
  /// 创建投屏码悬浮卡。
  const WbCastCodeOverlay({
    super.key,
    required this.controller,
    this.onOpenSettings,
  });

  /// 投屏控制器。
  final WbCastController controller;

  /// 打开投屏设置面板。
  final VoidCallback? onOpenSettings;

  @override
  State<WbCastCodeOverlay> createState() => _WbCastCodeOverlayState();
}

class _WbCastCodeOverlayState extends State<WbCastCodeOverlay> {
  static const double _cardWidth = 304;
  static const double _margin = 16;

  Offset _offset = Offset.zero;
  bool _collapsed = false;
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxLeft =
            math.max(_margin, constraints.maxWidth - _cardWidth - _margin);
        // 卡片高度随内联的设备列表增长（最多 maxSenders 路）；拖动上限预留
        // 260px，避免拖到底部时列表被裁掉。
        final double maxTop =
            math.max(_margin, constraints.maxHeight - 260);
        final double left = (_margin + _offset.dx).clamp(_margin, maxLeft);
        final double top = (_margin + _offset.dy).clamp(_margin, maxTop);
        return ListenableBuilder(
          listenable: widget.controller,
          builder: (BuildContext context, Widget? child) {
            final Widget card = _collapsed
                ? _buildCollapsed(colors)
                : _buildExpanded(colors);
            return Stack(
              children: <Widget>[
                Positioned(
                  left: left,
                  top: top,
                  width: _collapsed ? null : _cardWidth,
                  child: GestureDetector(
                    behavior: HitTestBehavior.deferToChild,
                    onPanUpdate: (DragUpdateDetails details) {
                      setState(() => _offset += details.delta);
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.basic,
                      child: card,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildCollapsed(WbThemeColors colors) {
    final WbCastController controller = widget.controller;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => setState(() => _collapsed = false),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: colors.elevated.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: colors.cardBorder),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.cast, size: 16, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                controller.hasActiveRoom
                    ? '投屏 ${controller.codeDisplay}'
                    : '局域网投屏',
                style: TextStyle(
                  color: colors.icon,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (controller.hasActiveRoom) ...<Widget>[
                const SizedBox(width: 8),
                Text(
                  '${controller.acceptedCount}/${controller.maxSenders}',
                  style: TextStyle(
                    color: colors.icon.withValues(alpha: 0.65),
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(width: 4),
              Icon(Icons.expand_more, size: 16, color: colors.icon),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded(WbThemeColors colors) {
    final WbCastController controller = widget.controller;
    final bool running = controller.hasActiveRoom;
    final String statusText = _statusText(controller);
    final Color statusColor = _statusColor(controller, colors);
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: colors.elevated.withValues(alpha: 0.98),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.cardBorder),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(colors, running, statusColor),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _codeRow(colors, controller),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          statusText,
                          style: TextStyle(
                            color: controller.errorMessage != null
                                ? const Color(0xFFD92D20)
                                : colors.icon.withValues(alpha: 0.72),
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
                      if (running)
                        Text(
                          '${controller.acceptedCount}/${controller.maxSenders} 路',
                          style: TextStyle(
                            color: colors.icon.withValues(alpha: 0.6),
                            fontSize: 12,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                    ],
                  ),
                  // 设备列表内联到本卡，不再单独占用右上角固定面板的位置。
                  if (controller.senders.isNotEmpty)
                    _senderList(colors, controller),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(WbThemeColors colors, bool running, Color statusColor) {
    final WbCastController controller = widget.controller;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
      child: Row(
        children: <Widget>[
          Icon(Icons.cast, size: 17, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '局域网投屏',
              style: TextStyle(
                color: colors.icon,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (!running)
            _iconAction(
              icon: Icons.refresh,
              tooltip: '重新生成投屏码',
              onTap: () => unawaited(controller.regenerateCode()),
            ),
          _iconAction(
            icon: Icons.settings_outlined,
            tooltip: '投屏设置',
            onTap: widget.onOpenSettings ?? () {},
          ),
          _iconAction(
            icon: Icons.keyboard_arrow_up,
            tooltip: '收起',
            onTap: () => setState(() => _collapsed = true),
          ),
        ],
      ),
    );
  }

  Widget _codeRow(WbThemeColors colors, WbCastController controller) {
    final bool ready = controller.hasActiveRoom;
    final bool visible = ready && controller.showCode;
    final String text = ready
        ? (visible ? controller.codeDisplay : '••••')
        : '----';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Text(
          text,
          style: TextStyle(
            color: ready ? colors.primary : colors.icon.withValues(alpha: 0.35),
            fontSize: 34,
            height: 1.05,
            fontWeight: FontWeight.w700,
            letterSpacing: 7,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        if (ready) ...<Widget>[
          _iconAction(
            icon: _copied ? Icons.check : Icons.copy_rounded,
            tooltip: _copied ? '已复制' : '复制投屏码',
            onTap: () => unawaited(_copy(controller.codeDisplay)),
          ),
          _iconAction(
            icon: visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            tooltip: visible ? '隐藏投屏码' : '显示投屏码',
            onTap: () => controller.setShowCode(!visible),
          ),
          _iconAction(
            icon: Icons.stop_circle_outlined,
            tooltip: '关闭投屏接收',
            onTap: () => unawaited(controller.endSession()),
          ),
        ],
      ],
    );
  }

  Widget _iconAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final WbThemeColors colors = context.wbColors;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 16, color: colors.icon.withValues(alpha: 0.7)),
        ),
      ),
    );
  }

  /// 已连接设备列表（并入投屏码卡，取代原先右上角常驻的
  /// `WbCastConnectionPanel`）。
  Widget _senderList(WbThemeColors colors, WbCastController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 10),
        Divider(height: 1, color: colors.cardBorder),
        const SizedBox(height: 6),
        for (final WbCastSenderSnapshot sender in controller.senders)
          _senderRow(colors, controller, sender),
        const SizedBox(height: 2),
      ],
    );
  }

  Widget _senderRow(
    WbThemeColors colors,
    WbCastController controller,
    WbCastSenderSnapshot sender,
  ) {
    final WbCastLinkState state = sender.accepted
        ? controller.linkStateOf(sender.senderId)
        : WbCastLinkState.pending;
    final Color dot = switch (state) {
      WbCastLinkState.connected => const Color(0xFF12B76A),
      WbCastLinkState.failed => const Color(0xFFF04438),
      WbCastLinkState.pending => const Color(0xFFF79009),
      WbCastLinkState.connecting => const Color(0xFF2E90FA),
      WbCastLinkState.closed => colors.icon.withValues(alpha: 0.35),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              sender.deviceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.icon, fontSize: 12),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            sender.reconnecting ? '重连中' : state.label,
            style: TextStyle(
              color: colors.icon.withValues(alpha: 0.55),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  static String _statusText(WbCastController controller) {
    if (controller.status == WbCastSessionStatus.connecting) {
      return '正在创建投屏房间…';
    }
    if (controller.errorMessage != null) return controller.errorMessage!;
    if (!controller.signalingOnline && controller.hasActiveRoom) {
      return '信令断开，正在重连…';
    }
    if (!controller.hasActiveRoom) return '尚未开启投屏接收';
    // 以实际连接数为准（自动接受时房间快照可能先于状态就绪）。
    if (controller.acceptedCount == 0) return '等待设备输入投屏码…';
    return '已连接 ${controller.acceptedCount} 路设备';
  }

  static Color _statusColor(WbCastController controller, WbThemeColors colors) {
    if (controller.errorMessage != null) return const Color(0xFFD92D20);
    if (controller.status == WbCastSessionStatus.connecting) {
      return const Color(0xFFF79009);
    }
    if (controller.hasActiveRoom) return const Color(0xFF12B76A);
    return colors.icon.withValues(alpha: 0.4);
  }
}

/// 视频浮层容器（每路一个独立、可拖动 / 缩放 / 最大化的窗口）。
class WbCastOverlayLayer extends StatefulWidget {
  /// 创建浮层容器。
  const WbCastOverlayLayer({
    super.key,
    required this.controller,
    this.padding = const EdgeInsets.all(16),
  });

  /// 投屏控制器。
  final WbCastController controller;

  /// 容器内边距（初始落位与拖动边界）。
  final EdgeInsets padding;

  @override
  State<WbCastOverlayLayer> createState() => _WbCastOverlayLayerState();
}

class _WbCastOverlayLayerState extends State<WbCastOverlayLayer> {
  final Map<String, Rect> _rects = <String, Rect>{};
  final Map<String, Rect> _restore = <String, Rect>{};

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return ListenableBuilder(
          listenable: widget.controller,
          builder: (BuildContext context, Widget? child) {
            final Map<String, WbCastVideoFeed> feeds = widget.controller.feeds;
            final List<String> ids = feeds.keys.toList(growable: false);
            _prune(ids);
            final Size size = constraints.biggest;
            final List<Widget> tiles = <Widget>[];
            for (int index = 0; index < ids.length; index += 1) {
              final String senderId = ids[index];
              final Rect rect = _rectFor(senderId, index, size);
              tiles.add(
                Positioned(
                  left: rect.left,
                  top: rect.top,
                  width: rect.width,
                  height: rect.height,
                  child: _WbCastVideoTile(
                    senderId: senderId,
                    deviceName: _deviceName(senderId),
                    state: widget.controller.linkStateOf(senderId),
                    feed: feeds[senderId]!,
                    maximized: _restore.containsKey(senderId),
                    onDrag: (Offset delta) => _move(senderId, delta, size),
                    onResize: (Offset delta) => _resize(senderId, delta, size),
                    onToggleMaximize: () => _toggleMaximize(senderId, size),
                    onDisconnect: () =>
                        unawaited(widget.controller.disconnectSender(senderId)),
                  ),
                ),
              );
            }
            return Stack(children: tiles);
          },
        );
      },
    );
  }

  String _deviceName(String senderId) {
    for (final WbCastSenderSnapshot item in widget.controller.senders) {
      if (item.senderId == senderId) return item.deviceName;
    }
    return '投屏设备';
  }

  void _prune(List<String> ids) {
    final Set<String> alive = ids.toSet();
    _rects.removeWhere((String key, Rect _) => !alive.contains(key));
    _restore.removeWhere((String key, Rect _) => !alive.contains(key));
  }

  Rect _rectFor(String senderId, int index, Size size) {
    final Rect? existing = _rects[senderId];
    if (existing != null) {
      final double width = math.min(existing.width, math.max(240, size.width - 16));
      final double height = math.min(existing.height, math.max(160, size.height - 16));
      final Rect clamped = Rect.fromLTWH(
        existing.left.clamp(0, math.max(0, size.width - width)),
        existing.top.clamp(0, math.max(0, size.height - height)),
        width,
        height,
      );
      _rects[senderId] = clamped;
      return clamped;
    }
    final double width = math.min(392, math.max(240, size.width - 32));
    final double height = math.min(268, math.max(180, size.height - 32));
    final double cascade = (index % 6) * 26.0;
    final double left = (widget.padding.left + cascade)
        .clamp(0, math.max(0, size.width - width));
    final double top = (widget.padding.top + cascade)
        .clamp(0, math.max(0, size.height - height));
    final Rect rect = Rect.fromLTWH(left, top, width, height);
    _rects[senderId] = rect;
    return rect;
  }

  void _move(String senderId, Offset delta, Size size) {
    final Rect? current = _rects[senderId];
    if (current == null || _restore.containsKey(senderId)) return;
    setState(() {
      _rects[senderId] = Rect.fromLTWH(
        (current.left + delta.dx).clamp(0, math.max(0, size.width - current.width)),
        (current.top + delta.dy).clamp(0, math.max(0, size.height - current.height)),
        current.width,
        current.height,
      );
    });
  }

  void _resize(String senderId, Offset delta, Size size) {
    final Rect? current = _rects[senderId];
    if (current == null || _restore.containsKey(senderId)) return;
    setState(() {
      final double width =
          (current.width + delta.dx).clamp(260, math.max(260, size.width - current.left));
      final double height =
          (current.height + delta.dy).clamp(180, math.max(180, size.height - current.top));
      _rects[senderId] = Rect.fromLTWH(current.left, current.top, width, height);
    });
  }

  void _toggleMaximize(String senderId, Size size) {
    final Rect? current = _rects[senderId];
    if (current == null) return;
    setState(() {
      final Rect? saved = _restore.remove(senderId);
      if (saved != null) {
        _rects[senderId] = saved;
        return;
      }
      _restore[senderId] = current;
      _rects[senderId] = Rect.fromLTWH(
        widget.padding.left,
        widget.padding.top,
        math.max(260, size.width - widget.padding.horizontal),
        math.max(180, size.height - widget.padding.vertical),
      );
    });
  }
}

class _WbCastVideoTile extends StatelessWidget {
  const _WbCastVideoTile({
    required this.senderId,
    required this.deviceName,
    required this.state,
    required this.feed,
    required this.maximized,
    required this.onDrag,
    required this.onResize,
    required this.onToggleMaximize,
    required this.onDisconnect,
  });

  final String senderId;
  final String deviceName;
  final WbCastLinkState state;
  final WbCastVideoFeed feed;
  final bool maximized;
  final ValueChanged<Offset> onDrag;
  final ValueChanged<Offset> onResize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF101828),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.cardBorder),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.24),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (DragUpdateDetails details) => onDrag(details.delta),
              onDoubleTap: onToggleMaximize,
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.only(left: 10, right: 2),
                  color: const Color(0xFF1D2939),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.drag_indicator, size: 15, color: Colors.white54),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          deviceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      _stateChip(),
                      const SizedBox(width: 4),
                      _headerButton(
                        icon: maximized ? Icons.fullscreen_exit : Icons.fullscreen,
                        tooltip: maximized ? '还原' : '全屏',
                        onTap: onToggleMaximize,
                      ),
                      _headerButton(
                        icon: Icons.close,
                        tooltip: '断开这一路',
                        onTap: onDisconnect,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  GestureDetector(
                    onDoubleTap: onToggleMaximize,
                    child: feed.renderer == null
                        ? const _VideoPlaceholder()
                        : RTCVideoView(
                            feed.renderer!,
                            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                            mirror: false,
                          ),
                  ),
                  if (state != WbCastLinkState.connected)
                    _ConnectingOverlay(state: state),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (DragUpdateDetails details) =>
                          onResize(details.delta),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeDownRight,
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CustomPaint(
                            painter: _ResizeGripPainter(
                              color: Colors.white.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      ),
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

  Widget _stateChip() {
    final Color color = switch (state) {
      WbCastLinkState.connected => const Color(0xFF12B76A),
      WbCastLinkState.failed => const Color(0xFFF04438),
      WbCastLinkState.pending => const Color(0xFFF79009),
      WbCastLinkState.connecting => const Color(0xFF2E90FA),
      WbCastLinkState.closed => Colors.white38,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          state.label,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }

  Widget _headerButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 16, color: Colors.white70),
        ),
      ),
    );
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF101828),
      child: Center(
        child: Icon(Icons.videocam_outlined, size: 34, color: Colors.white24),
      ),
    );
  }
}

class _ConnectingOverlay extends StatelessWidget {
  const _ConnectingOverlay({required this.state});

  final WbCastLinkState state;

  @override
  Widget build(BuildContext context) {
    final bool failed = state == WbCastLinkState.failed;
    return ColoredBox(
      color: Colors.black.withValues(alpha: failed ? 0.55 : 0.35),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (!failed)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
                ),
              )
            else
              const Icon(Icons.wifi_off_rounded, color: Colors.white70, size: 24),
            const SizedBox(height: 8),
            Text(
              failed ? '连接失败，等待重新投屏' : '正在建立视频连接…',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResizeGripPainter extends CustomPainter {
  const _ResizeGripPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (int index = 0; index < 3; index += 1) {
      final double offset = 5.0 + index * 5;
      canvas.drawLine(
        Offset(size.width - offset, size.height - 4),
        Offset(size.width - 4, size.height - offset),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ResizeGripPainter oldDelegate) => oldDelegate.color != color;
}

/// 发送端状态胶囊：展示本端推流状态与结束入口（不进入白板模型）。
///
/// 桌面与 Web 编辑页共用：位于画布右上角，随控制器状态刷新。
class WbCastSenderChip extends StatelessWidget {
  /// 创建发送端状态胶囊。
  const WbCastSenderChip({super.key, required this.controller});

  /// 投屏控制器。
  final WbCastController controller;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final String? senderId = controller.senderId;
    final WbCastLinkState link = senderId == null
        ? WbCastLinkState.connecting
        : controller.linkStateOf(senderId);
    final Color dot = switch (link) {
      WbCastLinkState.connected => const Color(0xFF12B76A),
      WbCastLinkState.failed => const Color(0xFFF04438),
      WbCastLinkState.pending => const Color(0xFFF79009),
      WbCastLinkState.connecting => const Color(0xFF2E90FA),
      WbCastLinkState.closed => colors.icon.withValues(alpha: 0.35),
    };
    final String stateText = controller.errorMessage ?? link.label;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: colors.elevated.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.cardBorder),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.screen_share_outlined, size: 16, color: colors.primary),
          const SizedBox(width: 8),
          Text(
            '正在投屏 · ${controller.mediaSource.label}',
            style: TextStyle(
              color: colors.icon,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            stateText,
            style: TextStyle(
              color: controller.errorMessage != null
                  ? const Color(0xFFD92D20)
                  : colors.icon.withValues(alpha: 0.6),
              fontSize: 11,
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: () => unawaited(controller.leaveAsSender()),
            style: TextButton.styleFrom(
              foregroundColor: colors.primary,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('结束投屏', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
