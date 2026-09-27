/// 引导与帮助模块的语义图标映射（[LinearIcons]）。
///
/// 内容数据（[WbGuideContent]）以字符串语义名携带图标，
/// UI 层通过 [wbGuideIcon] 统一解析，避免数据层依赖 UI 框架。
library;

import 'package:flutter/widgets.dart';
import 'package:whiteboard_icons/icons.dart';

/// 将语义图标名解析为线性图标（未知名称回退到信息图标）。
///
/// 语义名清单：`radial` / `stickyNote` / `text` / `connector` / `ai` /
/// `page` / `check` / `board` / `pen` / `undo` / `zoomIn` / `light` /
/// `info` / `search` / `close` / `settings` / `comment` / `cube` /
/// `share` / `warning`。
IconData wbGuideIcon(String name) {
  switch (name) {
    case 'radial':
      return LinearIcons.grid;
    case 'stickyNote':
      return LinearIcons.stickyNote;
    case 'text':
      return LinearIcons.text;
    case 'connector':
      return LinearIcons.connector;
    case 'ai':
      return LinearIcons.ai;
    case 'page':
      return LinearIcons.page;
    case 'check':
      return LinearIcons.check;
    case 'board':
      return LinearIcons.board;
    case 'pen':
      return LinearIcons.pen;
    case 'undo':
      return LinearIcons.undo;
    case 'zoomIn':
      return LinearIcons.zoomIn;
    case 'light':
      return LinearIcons.light;
    case 'info':
      return LinearIcons.info;
    case 'search':
      return LinearIcons.search;
    case 'close':
      return LinearIcons.close;
    case 'settings':
      return LinearIcons.settings;
    case 'comment':
      return LinearIcons.comment;
    case 'cube':
      return LinearIcons.cube;
    case 'share':
      return LinearIcons.share;
    case 'warning':
      return LinearIcons.warning;
    default:
      return LinearIcons.info;
  }
}
