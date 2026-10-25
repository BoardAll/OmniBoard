/// 发送端「输入投屏码」对话框。
///
/// 只做一件事：把四位码 + 媒体源交给 [WbCastController.join]，
/// 服务端校验房间类型 / 有效期 / 权限后由接收端确认（或自动接受）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whiteboard_theme/theme.dart';

import 'cast_controller.dart';
import 'cast_models.dart';

/// 输入四位投屏码并发起投屏。
class WbCastJoinDialog extends StatefulWidget {
  /// 创建对话框。
  const WbCastJoinDialog({
    super.key,
    required this.controller,
    this.deviceName,
    this.endpoint,
    this.token,
  });

  /// 投屏控制器。
  final WbCastController controller;

  /// 本机设备名（显示在接收端连接列表）。
  final String? deviceName;

  /// 服务地址覆盖（一般沿用控制器配置）。
  final String? endpoint;

  /// JWT 覆盖（可空）。
  final String? token;

  /// 以对话框形式打开；成功建立会话返回 true。
  static Future<bool?> show(
    BuildContext context,
    WbCastController controller, {
    String? deviceName,
    String? endpoint,
    String? token,
  }) {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.all(24),
          child: WbCastJoinDialog(
            controller: controller,
            deviceName: deviceName,
            endpoint: endpoint,
            token: token,
          ),
        );
      },
    );
  }

  @override
  State<WbCastJoinDialog> createState() => _WbCastJoinDialogState();
}

class _WbCastJoinDialogState extends State<WbCastJoinDialog> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _device = TextEditingController();
  final TextEditingController _endpoint = TextEditingController();
  final FocusNode _codeFocus = FocusNode();

  WbCastMediaSource _source = WbCastMediaSource.screen;
  bool _busy = false;
  bool _advanced = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _source = widget.controller.mediaSource;
    _device.text = widget.deviceName ?? _defaultDeviceName();
    _endpoint.text = widget.endpoint ?? widget.controller.endpoint;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _codeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _code.dispose();
    _device.dispose();
    _endpoint.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  String _defaultDeviceName() {
    if (kIsWeb) return '浏览器设备';
    return switch (defaultTargetPlatform) {
      TargetPlatform.windows => 'Windows 设备',
      TargetPlatform.macOS => 'Mac 设备',
      TargetPlatform.linux => 'Linux 设备',
      TargetPlatform.android => 'Android 设备',
      TargetPlatform.iOS => 'iPhone / iPad',
      TargetPlatform.fuchsia => 'Fuchsia 设备',
    };
  }

  Future<void> _submit() async {
    if (_busy) return;
    final String? code = WbCastCodes.normalize(_code.text);
    if (code == null) {
      setState(() => _error = '请输入接收端显示的四位投屏码');
      return;
    }
    final WbCastController controller = widget.controller;
    if (controller.role == WbCastRole.receiver && controller.hasActiveRoom) {
      setState(() => _error = '当前正在接收投屏，请先关闭投屏接收再发起投屏');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final bool ok = await controller.join(
      code: code,
      endpoint: _endpoint.text,
      token: widget.token,
      deviceName: _device.text,
      mediaSource: _source,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = controller.errorMessage ?? '发起投屏失败';
    });
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 400,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.screen_share_outlined, size: 18, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '发起投屏',
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
                  onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: colors.icon.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '输入接收端白板上显示的四位投屏码',
              style: TextStyle(
                color: colors.icon.withValues(alpha: 0.6),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            _codeField(colors),
            const SizedBox(height: 16),
            _label(colors, '投屏内容'),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: _sourceOption(
                    colors,
                    source: WbCastMediaSource.screen,
                    icon: Icons.desktop_windows_outlined,
                    title: '屏幕',
                    subtitle: kIsWeb ? '需 HTTPS / localhost' : '分享桌面窗口',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _sourceOption(
                    colors,
                    source: WbCastMediaSource.camera,
                    icon: Icons.videocam_outlined,
                    title: '摄像头',
                    subtitle: '分享本机画面',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _label(colors, '设备名称'),
            const SizedBox(height: 6),
            _textField(
              colors,
              controller: _device,
              hint: '显示在接收端连接列表',
              icon: Icons.devices_other_outlined,
            ),
            const SizedBox(height: 10),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() => _advanced = !_advanced),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      _advanced ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: colors.icon.withValues(alpha: 0.55),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '高级：服务地址',
                      style: TextStyle(
                        color: colors.icon.withValues(alpha: 0.55),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_advanced) ...<Widget>[
              const SizedBox(height: 4),
              _textField(
                colors,
                controller: _endpoint,
                hint: 'http://127.0.0.1:8790',
                icon: Icons.link,
              ),
              const SizedBox(height: 4),
              Text(
                '与接收端使用同一个 realtime 服务；面板只交换 SDP / ICE，媒体不过服务器。',
                style: TextStyle(
                  color: colors.icon.withValues(alpha: 0.45),
                  fontSize: 10.5,
                  height: 1.4,
                ),
              ),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              // 显式 live region：Flutter Web 的合并语义节点不会包含动态插入的错误文案，
              // 读屏与 UI 自动化都依赖这个独立节点获取失败原因。
              Semantics(
                liveRegion: true,
                container: true,
                label: _error!,
                child: ExcludeSemantics(
                  child: Container(
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
                        const Icon(
                          Icons.error_outline,
                          size: 15,
                          color: Color(0xFFD92D20),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(
                              color: Color(0xFFB42318),
                              fontSize: 11,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.icon,
                      side: BorderSide(color: colors.cardBorder),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _busy ? null : () => unawaited(_submit()),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text('开始投屏'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _codeField(WbThemeColors colors) {
    return TextField(
      controller: _code,
      focusNode: _codeFocus,
      enabled: !_busy,
      autofocus: true,
      textAlign: TextAlign.center,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(4),
      ],
      onChanged: (String value) {
        if (_error != null) setState(() => _error = null);
      },
      onSubmitted: (String _) => unawaited(_submit()),
      style: TextStyle(
        color: colors.primary,
        fontSize: 34,
        height: 1.1,
        fontWeight: FontWeight.w700,
        letterSpacing: 12,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
      decoration: InputDecoration(
        hintText: '0000',
        hintStyle: TextStyle(
          color: colors.icon.withValues(alpha: 0.22),
          fontSize: 34,
          letterSpacing: 12,
          fontWeight: FontWeight.w700,
        ),
        filled: true,
        fillColor: colors.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.primary, width: 1.4),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.cardBorder),
        ),
      ),
    );
  }

  Widget _sourceOption(
    WbThemeColors colors, {
    required WbCastMediaSource source,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final bool selected = _source == source;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _busy ? null : () => setState(() => _source = source),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? colors.primary.withValues(alpha: 0.1) : colors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? colors.primary : colors.cardBorder,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              size: 17,
              color: selected ? colors.primary : colors.icon.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      color: selected ? colors.primary : colors.icon,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.icon.withValues(alpha: 0.5),
                      fontSize: 10,
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

  Widget _label(WbThemeColors colors, String text) {
    return Text(
      text,
      style: TextStyle(
        color: colors.icon.withValues(alpha: 0.85),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _textField(
    WbThemeColors colors, {
    required TextEditingController controller,
    required String hint,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      enabled: !_busy,
      style: TextStyle(color: colors.icon, fontSize: 12.5),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(
          color: colors.icon.withValues(alpha: 0.35),
          fontSize: 12.5,
        ),
        prefixIcon: Icon(icon, size: 15, color: colors.icon.withValues(alpha: 0.5)),
        prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        filled: true,
        fillColor: colors.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colors.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colors.primary, width: 1.3),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colors.cardBorder),
        ),
      ),
    );
  }
}
