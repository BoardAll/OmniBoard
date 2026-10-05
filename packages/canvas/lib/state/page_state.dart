/// 页面状态：页面列表 / 当前页 / 增删改排序（桌面 / Web 共享）。
///
/// 由宿主编辑页在白板打开后调用 [attach] 绑定；引擎可用
/// （[WbPageOps.isAvailable]）时增删改走引擎，否则在内存列表上操作
/// （演示模式）。
///
/// 引擎调用面经 [WbPageOps] 抽象注入：桌面端为 FFI 实现
/// （`WbFfiPageOps`，包装 `WbFfiService.page`），Web 端为 WASM 实现
/// （包装 `WbPageService`），两端语义一致。
library;

import 'package:flutter/foundation.dart';
import 'package:whiteboard_core/wb_core_common.dart';

/// 页服务引擎桥（[WbPageState] 的唯一引擎依赖面）。
///
/// 方法形状与 `whiteboard_core` 的 `WbPageService` 对齐：返回值中
/// [create] / [rename] / [duplicate] 为页面对象，其余为结果通知。
abstract interface class WbPageOps {
  /// 引擎是否可用（false 时 [WbPageState] 走内存演示模式）。
  bool get isAvailable;

  /// 创建页面（[options] 可含 `name` / `background`）。
  WbPage create(String boardId, [Map<String, dynamic> options]);

  /// 重命名页面。
  WbPage rename(String pageId, String name);

  /// 删除页面。
  void delete(String pageId);

  /// 复制页面。
  WbPage duplicate(String pageId);

  /// 移动页面到新索引。
  void move(String pageId, int newIndex);

  /// 锁定 / 解锁页面。
  void lock(String pageId, bool locked);

  /// 隐藏 / 显示页面。
  void hide(String pageId, bool hidden);

  /// 设置页面背景（完整背景对象，见 background 域）。
  void setBackground(String pageId, Map<String, dynamic> background);
}

/// 空引擎桥：无引擎环境（纯内存演示 / 引擎加载失败降级）。
///
/// [isAvailable] 恒 false（[WbPageState] 永不走引擎路径）；引擎方法被
/// 误调时抛 [StateError]。
class WbDemoPageOps implements WbPageOps {
  const WbDemoPageOps();

  @override
  bool get isAvailable => false;

  StateError get _unavailable => StateError('引擎页服务未注入（演示模式）');

  @override
  WbPage create(String boardId, [Map<String, dynamic> options = const {}]) =>
      throw _unavailable;

  @override
  WbPage rename(String pageId, String name) => throw _unavailable;

  @override
  void delete(String pageId) => throw _unavailable;

  @override
  WbPage duplicate(String pageId) => throw _unavailable;

  @override
  void move(String pageId, int newIndex) => throw _unavailable;

  @override
  void lock(String pageId, bool locked) => throw _unavailable;

  @override
  void hide(String pageId, bool hidden) => throw _unavailable;

  @override
  void setBackground(String pageId, Map<String, dynamic> background) =>
      throw _unavailable;
}

/// 页面状态。
///
/// 由编辑页在白板打开后调用 [attach] 绑定；引擎可用时增删改走
/// [ops]，否则在内存列表上操作（演示模式）。
class WbPageState extends ChangeNotifier {
  WbPageState({required this.ops});

  /// 引擎页服务桥。
  final WbPageOps ops;

  String _boardId = '';
  List<WbPage> _pages = <WbPage>[];
  String _currentPageId = '';

  /// 本地页结构变更出口（协同注入：`WbCollabService.handlePageOp`；
  /// null 时无行为）。
  ///
  /// 参数：`pageId` / `field`（`create` / `delete` / `rename` / `move`）/ 
  /// `value`（create → `{'name': ...}`；delete → true；rename → 新名；
  /// move → 目标索引）。远端应用路径（[applyRemotePageOp]）不经过本出口
  /// （防空回发）。
  void Function(String pageId, String field, Object? value)? onPageOp;

  /// 引擎页创建的撞车重试上限（远端页先占同名 id 时逐个重试）。
  static const int _pageCreateRetries = 8;

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
  ///
  /// 引擎可用时经引擎取 id（进程内计数 `page-N`，可能与协同远端页 id
  /// 重叠）——撞车时重试直到取到未占用 id；成功后在列表尾部追加并选中，
  /// 经 [onPageOp] 外发 `create`。
  void addPage() {
    if (_boardId.isEmpty) {
      return;
    }
    try {
      final WbPage page = ops.isAvailable
          ? _createEnginePageAvoidingCollision()
          : WbPage(
              id: '$_boardId-page-${_pages.length + 1}',
              name: '页面 ${_pages.length + 1}',
            );
      _pages.add(page);
      _currentPageId = page.id;
      _emitPageOp(page.id, 'create', <String, dynamic>{'name': page.name});
    } catch (_) {
      // 引擎错误：保持现状（错误呈现由宿主通知中心统一处理）。
    }
    notifyListeners();
  }

  /// 引擎新建页并避开 id 撞车（协同远端页先占用返回 id 时重试丢弃）。
  ///
  /// 超出重试上限仍撞车 → 抛错（由 [addPage] 捕获，保持现状不产出
  /// 重复 id 页）。
  WbPage _createEnginePageAvoidingCollision() {
    WbPage page = ops.create(_boardId);
    int attempt = 0;
    while (_indexOf(page.id) >= 0 && attempt < _pageCreateRetries) {
      page = ops.create(_boardId);
      attempt++;
    }
    if (_indexOf(page.id) >= 0) {
      throw StateError('page id collision persists: ${page.id}');
    }
    return page;
  }

  /// 重命名页面。
  void rename(String pageId, String name) {
    final int index = _indexOf(pageId);
    if (index < 0 || name.isEmpty) {
      return;
    }
    try {
      if (ops.isAvailable) {
        ops.rename(pageId, name);
      }
    } catch (_) {
      // 引擎错误：仍更新本地视图。
    }
    _pages[index] = _pages[index].copyWith(name: name);
    _emitPageOp(pageId, 'rename', name);
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
      if (ops.isAvailable) {
        ops.delete(pageId);
      }
    } catch (_) {
      // 引擎错误：仍更新本地视图。
    }
    _pages.removeAt(index);
    if (_currentPageId == pageId) {
      _currentPageId = _pages.first.id;
    }
    _emitPageOp(pageId, 'delete', true);
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
      if (ops.isAvailable) {
        copy = ops.duplicate(pageId);
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
      _emitPageOp(copy.id, 'create', <String, dynamic>{'name': copy.name});
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
      if (ops.isAvailable) {
        ops.move(pageId, target);
      }
    } catch (_) {
      // 引擎错误：仍更新本地视图。
    }
    final WbPage page = _pages.removeAt(index);
    _pages.insert(target, page);
    _emitPageOp(pageId, 'move', target);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 页面高级操作（锁定 / 隐藏 / 背景 / 批量移动）。
  // ---------------------------------------------------------------------------

  /// 锁定 / 解锁页面（引擎可用时走引擎，否则仅更新本地视图）。
  ///
  /// 锁定页在列表中显示锁图标并禁止拖拽排序。
  void setLocked(String pageId, bool locked) {
    final int index = _indexOf(pageId);
    if (index < 0 || _pages[index].locked == locked) {
      return;
    }
    try {
      if (ops.isAvailable) {
        ops.lock(pageId, locked);
      }
    } catch (_) {
      // 引擎错误：仍更新本地视图。
    }
    _pages[index] = _pages[index].copyWith(locked: locked);
    notifyListeners();
  }

  /// 隐藏 / 显示页面（隐藏页在列表中半透明显示）。
  void setHidden(String pageId, bool hidden) {
    final int index = _indexOf(pageId);
    if (index < 0 || _pages[index].hidden == hidden) {
      return;
    }
    try {
      if (ops.isAvailable) {
        ops.hide(pageId, hidden);
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
      if (ops.isAvailable) {
        ops.setBackground(pageId, background);
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
  /// 引擎侧元素计数由渲染缩略图路径维护，无需经引擎写入。
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
      if (ops.isAvailable) {
        for (int i = 0; i < moved.length; i++) {
          ops.move(moved[i].id, insertAt + i);
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
    for (final WbPage page in moved) {
      final int finalIndex =
          _pages.indexWhere((WbPage item) => item.id == page.id);
      if (finalIndex >= 0) {
        _emitPageOp(page.id, 'move', finalIndex);
      }
    }
    notifyListeners();
  }

  /// 解绑（关闭白板时调用）。
  void detach() {
    _boardId = '';
    _pages = <WbPage>[];
    _currentPageId = '';
    notifyListeners();
  }

  // ---- 协同入口（页结构） -------------------------------------------------

  /// 确保远端页在本地列表存在（幂等；已存在忽略）。
  ///
  /// 元素 op 先于页结构 op 到达（或页结构 op 已随 op log 环形淘汰）时
  /// 兜底建页，避免远端笔迹落在不可见的「幽灵页」；名称取缺省「页面 N」
  /// （随后的 `rename` op 会纠正）。
  void ensureRemotePage(String pageId) {
    if (pageId.isEmpty || _indexOf(pageId) >= 0) {
      return;
    }
    _pages.add(WbPage(id: pageId, name: '页面 ${_pages.length + 1}'));
    notifyListeners();
  }

  /// 应用远端页结构 op（协同入口；幂等，不触发出口回发）。
  ///
  /// - `create`：value `{'name': ...}` → 列表尾部追加（已存在忽略；
  ///   名称缺省「页面 N」）；
  /// - `delete`：删除页（本地仅剩一页时保留——至少一页）；当前页被删
  ///   则切到第一页；
  /// - `rename`：value 新名（非空字符串）；
  /// - `move`：value 目标索引（num）。
  void applyRemotePageOp(String pageId, String field, Object? value) {
    if (pageId.isEmpty) {
      return;
    }
    switch (field) {
      case 'create':
        if (_indexOf(pageId) >= 0) {
          return;
        }
        String name = '';
        if (value is Map) {
          final Object? rawName = value['name'];
          if (rawName is String) {
            name = rawName;
          }
        }
        _pages.add(WbPage(
          id: pageId,
          name: name.isEmpty ? '页面 ${_pages.length + 1}' : name,
        ));
      case 'delete':
        final int index = _indexOf(pageId);
        if (index < 0 || _pages.length <= 1) {
          return;
        }
        _pages.removeAt(index);
        if (_currentPageId == pageId) {
          _currentPageId = _pages.first.id;
        }
      case 'rename':
        if (value is! String || value.isEmpty) {
          return;
        }
        final int index = _indexOf(pageId);
        if (index < 0) {
          return;
        }
        _pages[index] = _pages[index].copyWith(name: value);
      case 'move':
        if (value is! num) {
          return;
        }
        final int index = _indexOf(pageId);
        if (index < 0) {
          return;
        }
        final int target = value.toInt().clamp(0, _pages.length - 1);
        if (index == target) {
          return;
        }
        final WbPage page = _pages.removeAt(index);
        _pages.insert(target, page);
      default:
        return; // 未知字段：忽略（前向兼容）。
    }
    notifyListeners();
  }

  /// 发出页结构 op（出口未注入时静默跳过）。
  void _emitPageOp(String pageId, String field, Object? value) {
    onPageOp?.call(pageId, field, value);
  }

  int _indexOf(String pageId) =>
      _pages.indexWhere((WbPage page) => page.id == pageId);
}
