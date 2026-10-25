/// 投屏设置面板与连接列表。
///
/// 面板职责（与需求 7.4 对齐）：
/// - 开启 / 关闭投屏接收；
/// - 最大同时接收路数 1–4（默认 4），下调低于现有连接数时展示服务端提示，**不静默断开**；
/// - 显示 / 隐藏投屏码、复制、重新生成；
/// - 查看当前连接列表（设备名 / 状态 / 单路断开 / 待确认请求）；
/// - 展示必要的错误信息。
///
/// 面板只读写 [WbCastController]，不接触白板文档模型。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whiteboard_theme/theme.dart';

import 'cast_controller.dart';
import 'cast_models.dart';

/// 投屏设置面板（可作为对话框内容或侧栏内容直接嵌入）。
class WbCastSettingsSheet extends StatefulWidget {
  /// 创建设置面板。
  const WbCastSettingsSheet({
    super.key,
    required this.controller,
    this.onClose,
  });

  /// 投屏控制器。
  final WbCastController controller;

  /// 关闭回调（对话框场景默认 pop）。
  final VoidCallback? onClose;

  /// 以对话框形式打开设置面板。
  static Future<void> show(
    BuildContext context,
    WbCastController controller,
  ) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.all(24),
          child: WbCastSettingsSheet(controller: controller),
        );
      },
    );
  }

  @override
  State<WbCastSettingsSheet> createState() => _WbCastSettingsSheetState();
}

class _WbCastSettingsSheetState extends State<WbCastSettingsSheet> {
  bool _busy = false;
  int? _maxBusy;
  bool _copied = false;
  Timer? _copiedTimer;
  String? _notice;
  String? _maxError;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  WbCastController get _controller => widget.controller;

  Future<void> _toggleReceiver(bool enabled) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      if (enabled) {
        final bool ok = await _controller.startReceiver();
        if (!mounted) return;
        setState(() {
          _notice = ok ? null : (_controller.errorMessage ?? '开启投屏接收失败');
        });
      } else {
        await _controller.endSession();
        if (!mounted) return;
        setState(() => _notice = '已关闭投屏接收，原投屏码立即失效');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setMaxSenders(int value) async {
    if (_maxBusy != null) return;
    setState(() {
      _maxBusy = value;
      _maxError = null;
    });
    final String? error = await _controller.updateMaxSenders(value);
    if (!mounted) return;
    setState(() {
      _maxBusy = null;
      _maxError = error;
    });
  }

  Future<void> _regenerate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    final bool ok = await _controller.regenerateCode();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notice = ok ? '已重新生成投屏码，旧投屏码立即失效' : _controller.errorMessage;
    });
  }

  Future<void> _copyCode() async {
    final String code = _controller.codeDisplay;
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
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 392,
        constraints: const BoxConstraints(maxHeight: 640),
        decoration: BoxDecoration(
          color: colors.elevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.cardBorder),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 32,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: ListenableBuilder(
          listenable: _controller,
          builder: (BuildContext context, Widget? child) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _header(colors),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _receiverSwitch(colors),
                        const SizedBox(height: 14),
                        _codeSection(colors),
                        const SizedBox(height: 16),
                        _maxSendersSection(colors),
                        const SizedBox(height: 18),
                        _connectionSection(colors),
                        if (_controller.errorMessage != null) ...<Widget>[
                          const SizedBox(height: 14),
                          _errorBox(colors, _controller.errorMessage!),
                        ],
                        if (_notice != null) ...<Widget>[
                          const SizedBox(height: 12),
                          _noticeBox(colors, _notice!),
                        ],
                        const SizedBox(height: 16),
                        _footer(colors),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header(WbThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 10, 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.cast, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '投屏设置',
              style: TextStyle(
                color: colors.icon,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            visualDensity: VisualDensity.compact,
            onPressed: widget.onClose ?? () => Navigator.of(context).maybePop(),
            icon: Icon(
              Icons.close,
              size: 18,
              color: colors.icon.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _receiverSwitch(WbThemeColors colors) {
    final bool running = _controller.hasActiveRoom;
    final String subtitle = switch (_controller.status) {
      WbCastSessionStatus.connecting => '正在创建投屏房间…',
      WbCastSessionStatus.waiting => '等待设备输入投屏码…',
      WbCastSessionStatus.active => '已有 ${_controller.acceptedCount} 路设备在投屏',
      WbCastSessionStatus.pendingApproval => '等待确认新设备',
      WbCastSessionStatus.error => _controller.errorMessage ?? '投屏异常',
      WbCastSessionStatus.idle => '开启后其他设备可输入投屏码投屏',
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.cardBorder),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            running ? Icons.sensors : Icons.sensors_off,
            size: 18,
            color: running ? const Color(0xFF12B76A) : colors.icon.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '开启投屏接收',
                  style: TextStyle(
                    color: colors.icon,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: colors.icon.withValues(alpha: 0.62),
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: running || _controller.status == WbCastSessionStatus.connecting,
            onChanged: _busy ? null : (bool value) => unawaited(_toggleReceiver(value)),
          ),
        ],
      ),
    );
  }

  Widget _codeSection(WbThemeColors colors) {
    final bool ready = _controller.hasActiveRoom;
    final bool visible = ready && _controller.showCode;
    final String display = ready
        ? (visible ? _controller.codeDisplay : '••••')
        : '----';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _sectionLabel(colors, '投屏码'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.cardBorder),
          ),
          child: Row(
            children: <Widget>[
              Text(
                display,
                style: TextStyle(
                  color: ready ? colors.primary : colors.icon.withValues(alpha: 0.35),
                  fontSize: 30,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 6,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              if (ready)
                _smallAction(
                  colors,
                  icon: _copied ? Icons.check : Icons.copy_rounded,
                  label: _copied ? '已复制' : '复制',
                  onTap: () => unawaited(_copyCode()),
                ),
              if (ready)
                _smallAction(
                  colors,
                  icon: _controller.showCode
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  label: _controller.showCode ? '隐藏' : '显示',
                  onTap: () => _controller.setShowCode(!_controller.showCode),
                ),
              if (ready)
                _smallAction(
                  colors,
                  icon: Icons.refresh,
                  label: '换码',
                  onTap: _busy ? null : () => unawaited(_regenerate()),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          ready
              ? '投屏码即投屏房间号；旧码在重新生成后立即失效。'
              : '房间创建成功并拿到服务端分配的号码后，这里才会显示有效投屏码。',
          style: TextStyle(
            color: colors.icon.withValues(alpha: 0.55),
            fontSize: 11,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Widget _maxSendersSection(WbThemeColors colors) {
    final bool enabled = _controller.hasActiveRoom;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            _sectionLabel(colors, '最大同时接收'),
            const Spacer(),
            Text(
              '当前 ${_controller.acceptedCount} 路',
              style: TextStyle(
                color: colors.icon.withValues(alpha: 0.55),
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            for (int value = 1; value <= 4; value += 1) ...<Widget>[
              Expanded(
                child: _maxOption(colors, value, enabled),
              ),
              if (value != 4) const SizedBox(width: 8),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _maxError ?? '默认最多 4 路；下调到低于当前连接数时需先手动断开部分设备。',
          style: TextStyle(
            color: _maxError != null
                ? const Color(0xFFD92D20)
                : colors.icon.withValues(alpha: 0.55),
            fontSize: 11,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Widget _maxOption(WbThemeColors colors, int value, bool enabled) {
    final bool selected = _controller.maxSenders == value;
    final bool busy = _maxBusy == value;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: enabled && !selected && _maxBusy == null
          ? () => unawaited(_setMaxSenders(value))
          : null,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.primary.withValues(alpha: 0.12) : colors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? colors.primary : colors.cardBorder,
          ),
        ),
        child: busy
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
                ),
              )
            : Text(
                '$value 路',
                style: TextStyle(
                  color: selected
                      ? colors.primary
                      : colors.icon.withValues(alpha: enabled ? 0.75 : 0.3),
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
      ),
    );
  }

  Widget _connectionSection(WbThemeColors colors) {
    final List<WbCastSenderSnapshot> senders = _controller.senders;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            _sectionLabel(colors, '投屏连接'),
            const Spacer(),
            Text(
              '${_controller.acceptedCount}/${_controller.maxSenders}',
              style: TextStyle(
                color: colors.icon.withValues(alpha: 0.55),
                fontSize: 11,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (senders.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.cardBorder),
            ),
            child: Column(
              children: <Widget>[
                Icon(
                  Icons.devices_other_outlined,
                  size: 22,
                  color: colors.icon.withValues(alpha: 0.35),
                ),
                const SizedBox(height: 6),
                Text(
                  '暂无设备连接',
                  style: TextStyle(
                    color: colors.icon.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.cardBorder),
            ),
            child: Column(
              children: <Widget>[
                for (int index = 0; index < senders.length; index += 1) ...<Widget>[
                  if (index != 0)
                    Divider(height: 1, thickness: 1, color: colors.cardBorder),
                  _senderRow(colors, senders[index]),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _senderRow(WbThemeColors colors, WbCastSenderSnapshot sender) {
    final WbCastLinkState link = _controller.linkStateOf(sender.senderId);
    final WbCastLinkState state = sender.accepted ? link : WbCastLinkState.pending;
    final Color dot = switch (state) {
      WbCastLinkState.connected => const Color(0xFF12B76A),
      WbCastLinkState.failed => const Color(0xFFF04438),
      WbCastLinkState.pending => const Color(0xFFF79009),
      WbCastLinkState.connecting => const Color(0xFF2E90FA),
      WbCastLinkState.closed => colors.icon.withValues(alpha: 0.35),
    };
    final String label = sender.reconnecting ? '重连中' : state.label;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: Row(
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  sender.deviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.icon,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '$label · ${sender.senderId}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.icon.withValues(alpha: 0.55),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          if (state == WbCastLinkState.pending) ...<Widget>[
            _rowIcon(colors, Icons.check, '接受投屏', () {
              unawaited(_controller.approve(sender.senderId));
            }),
            _rowIcon(colors, Icons.close, '拒绝投屏', () {
              unawaited(_controller.reject(sender.senderId));
            }),
          ] else
            _rowIcon(colors, Icons.link_off, '断开这一路', () {
              unawaited(_controller.disconnectSender(sender.senderId));
            }),
        ],
      ),
    );
  }

  Widget _rowIcon(
    WbThemeColors colors,
    IconData icon,
    String tooltip,
    VoidCallback onTap,
  ) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon, size: 16, color: colors.icon.withValues(alpha: 0.62)),
        ),
      ),
    );
  }

  Widget _smallAction(
    WbThemeColors colors, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                size: 15,
                color: colors.icon.withValues(alpha: onTap == null ? 0.3 : 0.7),
              ),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(
                  color: colors.icon.withValues(alpha: onTap == null ? 0.3 : 0.7),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorBox(WbThemeColors colors, String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFDA29B)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.error_outline, size: 15, color: Color(0xFFD92D20)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFFB42318),
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _noticeBox(WbThemeColors colors, String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.cardBorder),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: colors.icon.withValues(alpha: 0.7),
          fontSize: 11,
          height: 1.4,
        ),
      ),
    );
  }

  Widget _footer(WbThemeColors colors) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(Icons.shield_outlined, size: 14, color: colors.icon.withValues(alpha: 0.4)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '四位投屏码仅用于局域网内便捷配对；房间有有效期，关闭或换码后旧码立即失效，'
            '错误的投屏码尝试会被限流。',
            style: TextStyle(
              color: colors.icon.withValues(alpha: 0.45),
              fontSize: 10.5,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(WbThemeColors colors, String text) {
    return Text(
      text,
      style: TextStyle(
        color: colors.icon.withValues(alpha: 0.85),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// 投屏连接列表面板。
///
/// 白板内已把设备列表**内联进 `WbCastCodeOverlay`**（可拖动 / 可折叠），
/// 不再单独常驻右上角；本类保留给需要独立面板的外部场景复用。
class WbCastConnectionPanel extends StatelessWidget {
  /// 创建连接列表面板。
  const WbCastConnectionPanel({
    super.key,
    required this.controller,
    this.onOpenSettings,
  });

  /// 投屏控制器。
  final WbCastController controller;

  /// 打开设置面板。
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        final List<WbCastSenderSnapshot> senders = controller.senders;
        return Container(
          width: 232,
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
          decoration: BoxDecoration(
            color: colors.elevated.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.cardBorder),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.cast_connected, size: 15, color: colors.primary),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '投屏连接',
                      style: TextStyle(
                        color: colors.icon,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${controller.acceptedCount}/${controller.maxSenders}',
                    style: TextStyle(
                      color: colors.icon.withValues(alpha: 0.55),
                      fontSize: 11,
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                  if (onOpenSettings != null)
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: onOpenSettings,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.tune,
                          size: 14,
                          color: colors.icon.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (senders.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    controller.hasActiveRoom ? '等待设备接入…' : '投屏接收未开启',
                    style: TextStyle(
                      color: colors.icon.withValues(alpha: 0.5),
                      fontSize: 11,
                    ),
                  ),
                )
              else
                for (final WbCastSenderSnapshot sender in senders)
                  _row(context, colors, sender),
            ],
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, WbThemeColors colors, WbCastSenderSnapshot sender) {
    final WbCastLinkState state =
        sender.accepted ? controller.linkStateOf(sender.senderId) : WbCastLinkState.pending;
    final Color dot = switch (state) {
      WbCastLinkState.connected => const Color(0xFF12B76A),
      WbCastLinkState.failed => const Color(0xFFF04438),
      WbCastLinkState.pending => const Color(0xFFF79009),
      WbCastLinkState.connecting => const Color(0xFF2E90FA),
      WbCastLinkState.closed => colors.icon.withValues(alpha: 0.35),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
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
              style: TextStyle(color: colors.icon, fontSize: 11.5),
            ),
          ),
          Text(
            sender.reconnecting ? '重连中' : state.label,
            style: TextStyle(
              color: colors.icon.withValues(alpha: 0.5),
              fontSize: 10,
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => unawaited(controller.disconnectSender(sender.senderId)),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close,
                size: 13,
                color: colors.icon.withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
