/// 画布引擎桥（共享）：图层面板 / 页面缩略图的引擎依赖面。
///
/// [WbCanvasEngine] 只覆盖「元素列表 / 行操作 / 缩略图」——页面增删改
/// 排序见 `state/page_state.dart` 的 `WbPageOps`。桌面端实现包装 FFI
/// （`WbFfiService`），Web 端实现包装 WASM 域服务（`WbElementService` /
/// `WbRenderService`），两端语义一致。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:whiteboard_core/wb_core_common.dart';

/// 画布元素引擎桥（共享实现无关）。
///
/// 方法形状与 `whiteboard_core` 的 `WbElementService` 对齐：
/// [listElements] 为数据源，[updateElement] / [deleteElement] 为行操作；
/// [thumbnail] 为引擎渲染的页面缩略图（null = 不可用 / 失败，回退静态
/// 预览）。
abstract interface class WbCanvasEngine {
  /// 引擎是否可用（false 时上层走演示缓存 / 静态预览）。
  bool get isAvailable;

  /// 元素列表（按页面 pageId；引擎不可用时调用方不应调用）。
  List<WbElement> listElements(String pageId);

  /// 更新元素（[patch] 局部字段）。
  void updateElement(String elementId, Map<String, dynamic> patch);

  /// 删除元素。
  void deleteElement(String elementId);

  /// 页面缩略图 PNG（宽高 0 表示引擎默认尺寸；null = 无缩略图）。
  Uint8List? thumbnail(String pageId, int width, int height);
}

/// 解析 `wb_render_thumbnail` 结果为 PNG bytes。
///
/// 兼容 `png` / `image` / `data` / `base64` 字段名（与既有桌面实现
/// 口径一致）；缺失 / 非法 base64 / 异常返回 null。
Uint8List? wbDecodeThumbnail(Map<String, dynamic> result) {
  try {
    final Object? data =
        result['png'] ?? result['image'] ?? result['data'] ?? result['base64'];
    if (data is String && data.isNotEmpty) {
      return base64Decode(data);
    }
  } catch (_) {
    // 非法 base64 / 解析异常：回退静态预览。
  }
  return null;
}
