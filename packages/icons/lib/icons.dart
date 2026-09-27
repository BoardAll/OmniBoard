/// Whiteboard 图标包 — 多风格语义图标集。
///
/// 提供 5 种视觉风格的语义图标集；所有风格共享同一组语义名，
/// 供主题系统整体切换图标风格：
///
/// - [WbIconStyle.linear] → [LinearIcons]（outlined 变体，默认）
/// - [WbIconStyle.filled] → [FilledIcons]（filled 变体）
/// - [WbIconStyle.minimal] → [MinimalIcons]（rounded 变体）
/// - [WbIconStyle.handDrawn] → [HandDrawnIcons]（当前 sharp 占位）
/// - [WbIconStyle.pixel] → [PixelIcons]（当前 sharp 占位）
///
/// 当前实现基于 Material Icons 变体；hand_drawn 与 pixel 风格预留
/// 自绘图标字体替换点（见各风格文件内 TODO）。
library;

export 'filled/filled_icons.dart';
export 'hand_drawn/hand_drawn_icons.dart';
export 'linear/linear_icons.dart';
export 'minimal/minimal_icons.dart';
export 'pixel/pixel_icons.dart';

/// 图标视觉风格。
enum WbIconStyle {
  /// 线性风格（outlined 变体）— 默认。
  linear('linear'),

  /// 填充风格（filled 变体）。
  filled('filled'),

  /// 极简风格（rounded 变体）。
  minimal('minimal'),

  /// 手绘风格（预留自绘字体，当前 sharp 占位）。
  handDrawn('hand_drawn'),

  /// 像素风格（预留像素字体，当前 sharp 占位）。
  pixel('pixel');

  const WbIconStyle(this.id);

  /// 持久化 / 跨端（C++ 主题 token）使用的稳定 id。
  final String id;

  /// 中文显示名。
  String get displayName => switch (this) {
        WbIconStyle.linear => '线性',
        WbIconStyle.filled => '填充',
        WbIconStyle.minimal => '极简',
        WbIconStyle.handDrawn => '手绘',
        WbIconStyle.pixel => '像素',
      };

  /// 从 [id] 解析风格；未知 id 回退到 [WbIconStyle.linear]。
  static WbIconStyle fromId(String id) {
    for (final WbIconStyle style in WbIconStyle.values) {
      if (style.id == id) {
        return style;
      }
    }
    return WbIconStyle.linear;
  }
}
