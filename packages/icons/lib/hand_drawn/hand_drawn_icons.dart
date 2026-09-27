import 'package:flutter/material.dart';

/// 手绘风格图标集。
///
/// TODO(Wave3): 当前映射到 Material sharp 变体作为占位，待自绘图标字体
/// （fontFamily: [preferredFontFamily]）就绪后替换为真实手绘图标。
abstract final class HandDrawnIcons {
  /// 预留的自绘字体族名；接入字体后替换各图标常量的 fontFamily。
  static const String preferredFontFamily = 'WbIconsHandDrawn';

  // ---- 编辑 ----
  static const IconData undo = Icons.undo_sharp;
  static const IconData redo = Icons.redo_sharp;
  static const IconData copy = Icons.content_copy_sharp;
  static const IconData paste = Icons.content_paste_sharp;
  static const IconData delete = Icons.delete_sharp;
  static const IconData duplicate = Icons.file_copy_sharp;
  static const IconData group = Icons.workspaces_sharp;
  static const IconData ungroup = Icons.call_split_sharp;
  static const IconData lock = Icons.lock_sharp;
  static const IconData unlock = Icons.lock_open_sharp;

  // ---- 工具 ----
  static const IconData select = Icons.near_me_sharp;
  static const IconData hand = Icons.pan_tool_sharp;
  static const IconData pen = Icons.edit_sharp;
  static const IconData highlighter = Icons.brush_sharp;
  static const IconData eraser = Icons.auto_fix_normal_sharp;
  static const IconData text = Icons.title_sharp;
  static const IconData shape = Icons.category_sharp;
  static const IconData image = Icons.image_sharp;
  static const IconData stickyNote = Icons.sticky_note_2_sharp;
  static const IconData comment = Icons.mode_comment_sharp;
  static const IconData connector = Icons.timeline_sharp;
  static const IconData table = Icons.table_chart_sharp;

  // ---- 内容模块 ----
  static const IconData flowchart = Icons.account_tree_sharp;
  static const IconData mindmap = Icons.hub_sharp;
  static const IconData formula = Icons.functions_sharp;
  static const IconData chart = Icons.insert_chart_sharp;

  // ---- 视图 ----
  static const IconData zoomIn = Icons.zoom_in_sharp;
  static const IconData zoomOut = Icons.zoom_out_sharp;
  static const IconData fitScreen = Icons.fit_screen_sharp;
  static const IconData grid = Icons.grid_on_sharp;
  static const IconData minimap = Icons.map_sharp;
  static const IconData fullscreen = Icons.fullscreen_sharp;
  static const IconData visible = Icons.visibility_sharp;

  // ---- 布局与对齐 ----
  static const IconData alignLeft = Icons.format_align_left_sharp;
  static const IconData alignCenter = Icons.format_align_center_sharp;
  static const IconData alignRight = Icons.format_align_right_sharp;
  static const IconData alignHorizontalLeft = Icons.align_horizontal_left_sharp;
  static const IconData alignHorizontalCenter = Icons.align_horizontal_center_sharp;
  static const IconData alignHorizontalRight = Icons.align_horizontal_right_sharp;
  static const IconData alignVerticalTop = Icons.align_vertical_top_sharp;
  static const IconData alignVerticalCenter = Icons.align_vertical_center_sharp;
  static const IconData alignVerticalBottom = Icons.align_vertical_bottom_sharp;
  static const IconData distributeHorizontal = Icons.horizontal_split_sharp;
  static const IconData distributeVertical = Icons.vertical_split_sharp;

  // ---- 格式 ----
  static const IconData bold = Icons.format_bold_sharp;
  static const IconData italic = Icons.format_italic_sharp;
  static const IconData underline = Icons.format_underline_sharp;
  static const IconData strikethrough = Icons.format_strikethrough_sharp;
  static const IconData fontSize = Icons.format_size_sharp;
  static const IconData textColor = Icons.format_color_text_sharp;
  static const IconData fillColor = Icons.format_color_fill_sharp;
  static const IconData borderStyle = Icons.border_style_sharp;
  static const IconData opacity = Icons.opacity_sharp;

  // ---- 层级 ----
  static const IconData bringForward = Icons.keyboard_arrow_up_sharp;
  static const IconData sendBackward = Icons.keyboard_arrow_down_sharp;
  static const IconData bringToFront = Icons.flip_to_front_sharp;
  static const IconData sendToBack = Icons.flip_to_back_sharp;

  // ---- 文件 ----
  static const IconData add = Icons.add_sharp;
  static const IconData folder = Icons.folder_sharp;
  static const IconData save = Icons.save_sharp;
  static const IconData export = Icons.ios_share_sharp;
  static const IconData import = Icons.file_download_sharp;
  static const IconData settings = Icons.settings_sharp;
  static const IconData share = Icons.share_sharp;
  static const IconData print = Icons.print_sharp;

  // ---- 导航 ----
  static const IconData home = Icons.home_sharp;
  static const IconData back = Icons.arrow_back_sharp;
  static const IconData forward = Icons.arrow_forward_sharp;
  static const IconData close = Icons.close_sharp;
  static const IconData check = Icons.check_sharp;
  static const IconData search = Icons.search_sharp;
  static const IconData more = Icons.more_horiz_sharp;
  static const IconData menu = Icons.menu_sharp;

  // ---- AI ----
  static const IconData ai = Icons.auto_awesome_sharp;
  static const IconData mic = Icons.mic_sharp;
  static const IconData send = Icons.send_sharp;
  static const IconData stop = Icons.stop_sharp;
  static const IconData refresh = Icons.refresh_sharp;

  // ---- 状态 ----
  static const IconData warning = Icons.warning_amber_sharp;
  static const IconData info = Icons.info_sharp;
  static const IconData error = Icons.error_sharp;
  static const IconData sync = Icons.sync_sharp;
  static const IconData cloud = Icons.cloud_sharp;
  static const IconData offline = Icons.cloud_off_sharp;

  // ---- 协作 ----
  static const IconData members = Icons.group_sharp;
  static const IconData history = Icons.history_sharp;
  static const IconData permission = Icons.admin_panel_settings_sharp;

  // ---- 图层与页面 ----
  static const IconData layers = Icons.layers_sharp;
  static const IconData page = Icons.description_sharp;
  static const IconData board = Icons.dashboard_sharp;
  static const IconData addPage = Icons.note_add_sharp;

  // ---- 3D ----
  static const IconData cube = Icons.view_in_ar_sharp;
  static const IconData rotate3d = Icons.threed_rotation_sharp;
  static const IconData light = Icons.lightbulb_sharp;

  // ---- 主题 ----
  static const IconData palette = Icons.palette_sharp;
  static const IconData darkMode = Icons.dark_mode_sharp;
  static const IconData lightMode = Icons.light_mode_sharp;

  // ---- 系统 ----
  static const IconData power = Icons.power_settings_new_sharp;
}
