/// 白板编辑页：响应式布局（宽屏左侧栏 + 画布区；窄屏单栏 + 底部工具条）。
///
/// WASM 接线（《Web 端方案设计（Flutter Web + WASM）v1.0》§6.1、§9.4）：
/// 首帧后调用 [WbCoreService.initialize] —— 注入 `wb_core.js`、实例化
/// `wb_core.wasm`；加载失败 / 产物缺失（Wave 4 前占位脚本）时不阻塞 UI，
/// 画布降级为内置演示视图（[WbDemoCanvas]），状态见 [WbCoreStatusChip]。
///
/// W1 协作层（T1.8）：首帧后连接 realtime 服务并加入当前白板房间
/// （失败不阻塞 UI）；AppBar 展示连接状态（[WbCollabStatusChip]）与
/// 参与者入口（[WbParticipantsButton] → endDrawer [WbParticipantsPanel]）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';
import 'package:whiteboard_web_platform/whiteboard_web_platform.dart';

import '../services/realtime_service.dart';
import '../services/wb_core_service.dart';
import '../widgets/collab/collab_status_chip.dart';
import '../widgets/collab/participants_button.dart';
import '../widgets/collab/participants_panel.dart';
import '../widgets/core_status_chip.dart';
import '../widgets/demo_canvas.dart';

/// 宽屏断点（逻辑像素，Material 布局规范）。
const double kWideBreakpoint = 840;

/// 白板编辑页。
class BoardEditPage extends StatefulWidget {
  /// 创建编辑页。
  const BoardEditPage({
    super.key,
    required this.boardId,
    this.boardName = '',
  });

  /// 白板 id（路由参数）。
  final String boardId;

  /// 白板名称（路由查询参数，可空）。
  final String boardName;

  @override
  State<BoardEditPage> createState() => _BoardEditPageState();
}

class _BoardEditPageState extends State<BoardEditPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final WbRealtimeService _realtime;

  @override
  void initState() {
    super.initState();
    _realtime = context.read<WbRealtimeService>();
    // 首帧后按需加载 WASM 核心：失败降级演示画布，不阻塞 UI。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(context.read<WbCoreService>().initialize());
      // W1 协作层：连接 + 加入当前房间（幂等；失败不阻塞 UI）。
      unawaited(_realtime.connect(kWbRealtimeEndpoint));
      unawaited(_realtime.joinBoard(widget.boardId));
    });
  }

  @override
  void dispose() {
    // 退出页面：离开房间（服务端广播 left 并关闭连接，§5.14）。
    unawaited(_realtime.leave());
    super.dispose();
  }

  void _leave() => context.pop();

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Scaffold(
      key: _scaffoldKey,
      endDrawer: const WbParticipantsPanel(),
      appBar: AppBar(
        backgroundColor: colors.surface,
        leading: IconButton(
          tooltip: '返回列表',
          icon: const Icon(LinearIcons.back),
          onPressed: _leave,
        ),
        title: Row(
          children: <Widget>[
            Flexible(
              child: Text(
                widget.boardName.isEmpty
                    ? '白板 ${widget.boardId}'
                    : widget.boardName,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            const WbCoreStatusChip(),
            const SizedBox(width: 8),
            const WbCollabStatusChip(),
          ],
        ),
        actions: <Widget>[
          WbParticipantsButton(
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
          const _FullscreenButton(),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= kWideBreakpoint;
          return Column(
            children: <Widget>[
              Expanded(
                child: wide
                    ? Row(
                        children: <Widget>[
                          const SizedBox(width: 240, child: _ToolPanel()),
                          const VerticalDivider(width: 1),
                          Expanded(child: _canvasArea()),
                        ],
                      )
                    : _canvasArea(),
              ),
              if (!wide) const _BottomToolBar(),
            ],
          );
        },
      ),
    );
  }

  /// 画布区：演示画面 + 降级提示（核心不可用时）。
  Widget _canvasArea() {
    return const Stack(
      children: <Widget>[
        Positioned.fill(child: WbDemoCanvas()),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Center(child: _FallbackBanner()),
        ),
      ],
    );
  }
}

/// 降级提示条：仅当 WASM 核心不可用时显示（不阻塞画布交互）。
class _FallbackBanner extends StatelessWidget {
  const _FallbackBanner();

  @override
  Widget build(BuildContext context) {
    final WbCoreService core = context.watch<WbCoreService>();
    if (core.status != WbCoreStatus.unavailable) {
      return const SizedBox.shrink();
    }
    final WbThemeColors colors = context.wbColors;
    return Material(
      color: colors.elevated,
      elevation: 2,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(LinearIcons.info, size: 16, color: colors.primary),
            const SizedBox(width: 8),
            const Flexible(
              child: WbText(
                '未检测到 WASM 核心（wb_core.js 为占位脚本），当前为内置演示画布',
                variant: WbTextVariant.caption,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 演示工具清单（图标 + 中文名；接入 C++ 工具系统在后续 Wave）。
const List<(IconData, String)> _demoTools = <(IconData, String)>[
  (LinearIcons.select, '选择'),
  (LinearIcons.hand, '抓手'),
  (LinearIcons.pen, '画笔'),
  (LinearIcons.highlighter, '荧光笔'),
  (LinearIcons.eraser, '橡皮'),
  (LinearIcons.text, '文本'),
  (LinearIcons.shape, '形状'),
  (LinearIcons.stickyNote, '便签'),
  (LinearIcons.connector, '连接线'),
  (LinearIcons.table, '表格'),
  (LinearIcons.flowchart, '流程图'),
  (LinearIcons.mindmap, '脑图'),
  (LinearIcons.formula, '公式'),
];

/// 工具面板（宽屏左侧栏；演示选择态）。
///
/// 外层用 [Material]（而非带色 Container）承载 ListTile 的背景与
/// 水波纹绘制，避免被中间 ColoredBox 遮挡（Flutter ListTile 断言要求）。
class _ToolPanel extends StatefulWidget {
  const _ToolPanel();

  @override
  State<_ToolPanel> createState() => _ToolPanelState();
}

class _ToolPanelState extends State<_ToolPanel> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Material(
      color: colors.sidebarBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: WbText('工具', variant: WbTextVariant.label),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _demoTools.length,
              itemBuilder: (BuildContext context, int index) {
                final (IconData icon, String label) = _demoTools[index];
                final bool selected = index == _selected;
                return ListTile(
                  dense: true,
                  selected: selected,
                  leading: Icon(
                    icon,
                    size: 20,
                    color: selected ? colors.primary : colors.icon,
                  ),
                  title: Text(label),
                  onTap: () => setState(() => _selected = index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部工具条（窄屏单栏布局；演示占位）。
class _BottomToolBar extends StatelessWidget {
  const _BottomToolBar();

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    return Material(
      color: colors.toolbarBackground,
      child: SizedBox(
        height: 60,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: _demoTools.length,
          itemBuilder: (BuildContext context, int index) {
            final (IconData icon, String label) = _demoTools[index];
            return Tooltip(
              message: label,
              child: IconButton(
                icon: Icon(icon),
                color: colors.toolbarIcon,
                // 窄屏工具条为演示占位：接入 C++ 工具系统在后续 Wave。
                onPressed: () {},
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 全屏切换按钮（映射浏览器 Fullscreen API，见 platform/web）。
class _FullscreenButton extends StatefulWidget {
  const _FullscreenButton();

  @override
  State<_FullscreenButton> createState() => _FullscreenButtonState();
}

class _FullscreenButtonState extends State<_FullscreenButton> {
  final WebWindowPlugin _window = WebWindowPlugin();
  bool _fullscreen = false;

  Future<void> _toggle() async {
    // 非 Web / 被浏览器拒绝时静默 no-op（见 platform/web 文档）。
    await _window.setFullscreen(!_fullscreen);
    if (mounted) {
      setState(() => _fullscreen = !_fullscreen);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: _fullscreen ? '退出全屏' : '全屏',
      icon: const Icon(LinearIcons.fullscreen),
      onPressed: () => unawaited(_toggle()),
    );
  }
}
