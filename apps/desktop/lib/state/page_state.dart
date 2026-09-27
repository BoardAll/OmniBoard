/// 页面状态：页面列表 / 当前页 / 增删改排序。
library;

import 'package:flutter/foundation.dart';
import 'package:whiteboard_core/wb_core.dart';

import '../services/ffi_service.dart';

/// 页面状态。
///
/// 由编辑页在白板打开后调用 [attach] 绑定；引擎可用时增删改走 FFI，
/// 否则在内存列表上操作（演示模式）。
class WbPageState extends ChangeNotifier {
  WbPageState({required this.ffi});

  /// FFI 服务。
  final WbFfiService ffi;

  String _boardId = '';
  List<WbPage> _pages = <WbPage>[];
  String _currentPageId = '';

  /// 当前白板 id（未绑定时为空串）。
  String get boardId => _boardId;

  /// 页面列表（不可变视图）。
  List<WbPage> get pages => List<WbPage>.unmodifiable(_pages);

  /// 当前页面 id。
  String get currentPageId => _currentPageId;

  /// 当前页面（无页面返回 null）。
  WbPage? get currentPage {
    for (final WbPage page in _pages) {
      if (page.id == _currentPageId) {
        return page;
      }
    }
    return null;
  }

  /// 是否无页面。
  bool get isEmpty => _pages.isEmpty;

  /// 绑定白板并装载页面列表（默认选中第一页）。
  void attach(WbBoard board) {
    _boardId = board.id;
    _pages = List<WbPage>.of(board.pages);
    _currentPageId = _pages.isEmpty ? '' : _pages.first.id;
    notifyListeners();
  }

  /// 从本地文件恢复页面列表（打开 `.wbd` 后调用）。
  ///
  /// [pages] 为空时回退占位单页（白板至少一页）；[currentPageId] 无效时
  /// 选中第一页。不触碰引擎（文件加载口径与 [attach] 演示模式一致）。
  void restore({
    required String boardId,
    required List<WbPage> pages,
    String currentPageId = '',
  }) {
    _boardId = boardId;
    _pages = List<WbPage>.of(pages);
    if (_pages.isEmpty) {
      _pages = <WbPage>[
        WbPage(id: '$boardId-page-1', name: '页面 1'),
      ];
    }
    final bool valid = currentPageId.isNotEmpty &&
        _pages.any((WbPage page) => page.id == currentPageId);
    _currentPageId = valid ? currentPageId : _pages.first.id;
    notifyListeners();
  }

  /// 切换当前页（未知 id 忽略）。
  void select(String pageId) {
    if (_currentPageId == pageId || _indexOf(pageId) < 0) {
      return;
    }
    _currentPageId = pageId;
    notifyListeners();
  }

  /// 新建页面并选中。
  void addPage() {
    if (_boardId.isEmpty) {
      return;
    }
    try {
      final WbPage page = ffi.isAvailable
          ? ffi.page.create(_boardId)
          : WbPage(
              id: '$_boardId-page-${_pages.length + 1}',
              name: '页面 ${_pages.length + 1}',
            );
      _pages.add(page);
      _currentPageId = page.id;
    } catch (_) {
      // 引擎错误：保持现状（错误呈现由 Wave 3 的通知中心统一处理）。
    }
    notifyListeners();
  }

  /// 重命名页面。
  void rename(String pageId, String name) {
    final int index = _indexOf(pageId);
    if (index < 0 || name.isEmpty) {
      return;
    }
    try {
      if (ffi.isAvailable) {
        ffi.page.rename(pageId, name);
      }
    } catch (_) {
      // 引擎错误：仍更新本地视图。
    }
    _pages[index] = _pages[index].copyWith(name: name);
    notifyListeners();
  }

  /// 删除页面（至少保留一页）。
  void remove(String pageId) {
    if (_pages.length <= 1) {
      return;
    }
    final int index = _indexOf(pageId);
    if (index < 0) {
      return;
    }
    try {
      if (ffi.isAvailable) {
        ffi.page.delete(pageId);
      }
    } catch (_) {
      // 引擎错误：仍更新本地视图。
    }
    _pages.removeAt(index);
    if (_currentPageId == pageId) {
      _currentPageId = _pages.first.id;
    }
    notifyListeners();
  }

  /// 复制页面（副本插入源页之后并选中）。
  void duplicate(String pageId) {
    final int index = _indexOf(pageId);
    if (index < 0) {
      return;
    }
    try {
      final WbPage copy;
      if (ffi.isAvailable) {
        copy = ffi.page.duplicate(pageId);
        _pages.insert(index + 1, copy);
      } else {
        final WbPage source = _pages[index];
        copy = WbPage(
          id: '${source.id}-copy-${_pages.length + 1}',
          name: '${source.name} 副本',
          background: source.background,
          elementCount: source.elementCount,
        );
        _pages.insert(index + 1, copy);
      }
      _currentPageId = copy.id;
    } catch (_) {
      // 引擎错误：放弃复制。
    }
    notifyListeners();
  }

  /// 移动页面到新索引。
  void move(String pageId, int newIndex) {
    final int index = _indexOf(pageId);
    if (index < 0) {
      return;
    }
    final int target = newIndex.clamp(0, _pages.length - 1);
    if (index == target) {
      return;
    }
    try {
      if (ffi.isAvailable) {
        ffi.page.move(pageId, target);
      }
    } catch (_) {
      // 引擎错误：仍更新本地视图。
    }
    final WbPage page = _pages.removeAt(index);
    _pages.insert(target, page);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Wave 3 增量扩展：页面高级操作（锁定 / 隐藏 / 背景 / 批量移动）。
  // 以下方法均为新增，不影响既有成员的名称与语义。
  // ---------------------------------------------------------------------------

  /// 锁定 / 解锁页面（引擎可用时走 FFI，否则仅更新本地视图）。
  ///
  /// 锁定页在列表中显示锁图标并禁止拖拽排序（design §4.10）。
  void setLocked(String pageId, bool locked) {
    final int index = _indexOf(pageId);
    if (index < 0 || _pages[index].locked == locked) {
      return;
    }
    try {
      if (ffi.isAvailable) {
        ffi.page.lock(pageId, locked);
      }
    } catch (_) {
      // 引擎错误：仍更新本地视图。
    }
    _pages[index] = _pages[index].copyWith(locked: locked);
    notifyListeners();
  }

  /// 隐藏 / 显示页面（隐藏页在列表中半透明显示，design §4.10）。
  void setHidden(String pageId, bool hidden) {
    final int index = _indexOf(pageId);
    if (index < 0 || _pages[index].hidden == hidden) {
      return;
    }
    try {
      if (ffi.isAvailable) {
        ffi.page.hide(pageId, hidden);
      }
    } catch (_) {
      // 引擎错误：仍更新本地视图。
    }
    _pages[index] = _pages[index].copyWith(hidden: hidden);
    notifyListeners();
  }

  /// 设置页面背景（[background] 为完整背景对象，见 background 域）。
  void setBackground(String pageId, Map<String, dynamic> background) {
    final int index = _indexOf(pageId);
    if (index < 0 || background.isEmpty) {
      return;
    }
    try {
      if (ffi.isAvailable) {
        ffi.page.setBackground(pageId, background);
      }
    } catch (_) {
      // 引擎错误：仍更新本地视图（缩略图背景色随之更新）。
    }
    _pages[index] = _pages[index].copyWith(
      background: Map<String, dynamic>.of(background),
    );
    notifyListeners();
  }

  /// 更新页面元素数（本地视图）。
  ///
  /// 画布控制器元素数变化时由宿主防抖同步，供缩略图角标「N 元素」显示；
  /// 引擎侧元素计数由渲染缩略图路径维护，无需经 FFI 写入。
  void setElementCount(String pageId, int count) {
    final int index = _indexOf(pageId);
    if (index < 0 || _pages[index].elementCount == count) {
      return;
    }
    _pages[index] = _pages[index].copyWith(elementCount: count);
    notifyListeners();
  }

  /// 批量移动页面到 [targetIndex] 插入位。
  ///
  /// [ids] 顺序无关（按当前列表顺序取）；[targetIndex] 为**原列表坐标**下的
  /// “插入到该索引之前”（取值 `0..pages.length`，等于长度表示移到末尾）。
  /// 典型用法：拖拽排序（拖到第 i 张卡片前 → `targetIndex = i`）。
  void moveMany(List<String> ids, int targetIndex) {
    if (ids.isEmpty) {
      return;
    }
    final Set<String> idSet = ids.toSet();
    final List<WbPage> moved = <WbPage>[
      for (final WbPage page in _pages)
        if (idSet.contains(page.id)) page,
    ];
    if (moved.isEmpty) {
      return;
    }
    final List<WbPage> remaining = <WbPage>[];
    int before = 0;
    for (int i = 0; i < _pages.length; i++) {
      if (idSet.contains(_pages[i].id)) {
        if (i < targetIndex) {
          before++;
        }
      } else {
        remaining.add(_pages[i]);
      }
    }
    final int insertAt = (targetIndex - before).clamp(0, remaining.length);
    try {
      if (ffi.isAvailable) {
        for (int i = 0; i < moved.length; i++) {
          ffi.page.move(moved[i].id, insertAt + i);
        }
      }
    } catch (_) {
      // 引擎错误：仍更新本地视图。
    }
    _pages = <WbPage>[
      ...remaining.sublist(0, insertAt),
      ...moved,
      ...remaining.sublist(insertAt),
    ];
    notifyListeners();
  }

  /// 解绑（关闭白板时调用）。
  void detach() {
    _boardId = '';
    _pages = <WbPage>[];
    _currentPageId = '';
    notifyListeners();
  }

  int _indexOf(String pageId) =>
      _pages.indexWhere((WbPage page) => page.id == pageId);
}
