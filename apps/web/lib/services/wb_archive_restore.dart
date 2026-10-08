/// 存档 → 引擎恢复（Web 多页持久化，P2）。
///
/// 刷新后 WASM 引擎为全新实例（白板 / 页面均重建），本地存档
/// （`wb.canvas.<boardId>`，`.wbd` JSON）是唯一权威来源：本工具把
/// 存档页面与引擎页面对齐 —— 同 id 复用（名 / 背景 / 锁定隐藏回写
/// 引擎），缺页经引擎新建（引擎分配 id），未匹配的引擎余页删除
/// （孤儿清理，避免默认页 / 导入残留堆积）。
///
/// 输出：页面列表（id 取引擎实际页 id，字段取存档）、整板元素
/// （画布 `loadBoardData` 入参）与恢复后的当前页 id。
///
/// 引擎不可用（`ops.isAvailable` false）或单步调用异常时按存档原样
/// 输出（id 用存档 id，不做引擎对齐）；本工具不抛异常。
library;

import 'package:whiteboard_canvas/canvas/canvas_model.dart';
import 'package:whiteboard_canvas/services/board_file_codec.dart';
import 'package:whiteboard_canvas/state/page_state.dart';
import 'package:whiteboard_core/wb_core_common.dart';

import 'wb_canvas_storage.dart';
import 'wb_persistent_canvas_store.dart';

/// 存档恢复结果（页面状态 + 画布整板载入 + 当前页）。
class WbArchiveRestoreResult {
  const WbArchiveRestoreResult({
    required this.pages,
    required this.elementsByPage,
    required this.currentPageId,
  });

  /// 页面列表（id 为引擎实际页 id，字段取存档）。
  final List<WbPage> pages;

  /// 引擎页 id → 元素列表（画布整板载入入参）。
  final Map<String, List<WbCanvasElement>> elementsByPage;

  /// 恢复后的当前页 id（引擎页 id；无页面时为空串）。
  final String currentPageId;
}

/// 读取本地存档（无 / 损坏 / 非白板文件返回 null；不抛异常）。
WbBoardData? readWbArchive(WbCanvasStorage storage, String boardId) {
  final String? source =
      storage.read('${WbPersistentCanvasStore.keyPrefix}$boardId');
  if (source == null || source.isEmpty) {
    return null;
  }
  try {
    return WbBoardFileCodec.decode(source);
  } on FormatException {
    // 损坏 / 非白板文件：视为无存档（下一次写穿会覆盖）。
    return null;
  }
}

/// 把存档恢复到引擎（返回对齐结果；不抛异常）。
///
/// [enginePages] 为引擎当前页列表（`WbBoard` 快照），用于同 id 复用；
/// 未匹配的存档页经 [ops] 新建（引擎生成新 id 并回写字段）；未被任何
/// 存档页匹配的引擎余页经 [ops] 删除（孤儿清理）。
WbArchiveRestoreResult restoreWbArchive({
  required WbBoardData archive,
  required WbPageOps ops,
  required String boardId,
  List<WbPage> enginePages = const <WbPage>[],
}) {
  final List<WbPage> remaining = List<WbPage>.of(enginePages);
  final List<WbPage> pages = <WbPage>[];
  final Map<String, List<WbCanvasElement>> elementsByPage =
      <String, List<WbCanvasElement>>{};
  String currentPageId = '';

  for (final WbBoardPageData archived in archive.pages) {
    WbPage? enginePage;
    final int matchIndex =
        remaining.indexWhere((WbPage page) => page.id == archived.id);
    if (matchIndex >= 0) {
      enginePage = remaining.removeAt(matchIndex);
    } else if (ops.isAvailable) {
      try {
        enginePage = ops.create(
          boardId,
          <String, dynamic>{
            if (archived.name.isNotEmpty) 'name': archived.name,
          },
        );
      } catch (_) {
        // 引擎错误：按存档 id 原样恢复（元素仍写本地存档）。
        enginePage = null;
      }
    }
    final String id = enginePage?.id ?? archived.id;
    if (enginePage != null && ops.isAvailable) {
      _syncPageFields(ops, id, archived);
    }
    pages.add(
      WbPage(
        id: id,
        name: archived.name,
        locked: archived.locked,
        hidden: archived.hidden,
        background: archived.background ?? const <String, dynamic>{},
        elementCount: archived.elements.length,
      ),
    );
    elementsByPage[id] = List<WbCanvasElement>.of(archived.elements);
    if (archived.id == archive.currentPageId) {
      currentPageId = id;
    }
  }

  // 孤儿清理：引擎中未被存档匹配的页删除（默认页 / 导入残留）。
  if (ops.isAvailable) {
    for (final WbPage orphan in remaining) {
      try {
        ops.delete(orphan.id);
      } catch (_) {
        // 引擎错误：忽略（孤儿页无 UI 引用，不影响数据）。
      }
    }
  }

  if (pages.isNotEmpty && currentPageId.isEmpty) {
    currentPageId = pages.first.id;
  }
  return WbArchiveRestoreResult(
    pages: pages,
    elementsByPage: elementsByPage,
    currentPageId: currentPageId,
  );
}

/// 把存档页字段（名 / 背景 / 锁定 / 隐藏）回写引擎（尽力而为）。
void _syncPageFields(WbPageOps ops, String pageId, WbBoardPageData archived) {
  try {
    if (archived.name.isNotEmpty) {
      ops.rename(pageId, archived.name);
    }
  } catch (_) {
    // 引擎错误：忽略（页面状态以存档为准）。
  }
  try {
    final Map<String, dynamic>? background = archived.background;
    if (background != null && background.isNotEmpty) {
      ops.setBackground(pageId, background);
    }
  } catch (_) {
    // 引擎错误：忽略。
  }
  try {
    if (archived.locked) {
      ops.lock(pageId, true);
    }
  } catch (_) {
    // 引擎错误：忽略。
  }
  try {
    if (archived.hidden) {
      ops.hide(pageId, true);
    }
  } catch (_) {
    // 引擎错误：忽略。
  }
}
