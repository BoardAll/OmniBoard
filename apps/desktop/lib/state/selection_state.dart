/// 选区状态：当前选中元素集合。
library;

import 'package:flutter/foundation.dart';

/// 选区状态（纯内存，命令执行后由编辑页回写）。
class WbSelectionState extends ChangeNotifier {
  final Set<String> _ids = <String>{};

  /// 选中元素 id 集合（不可变视图）。
  Set<String> get ids => Set<String>.unmodifiable(_ids);

  /// 选中数量。
  int get count => _ids.length;

  /// 是否无选中。
  bool get isEmpty => _ids.isEmpty;

  /// 是否有选中。
  bool get hasSelection => _ids.isNotEmpty;

  /// 指定元素是否选中。
  bool contains(String id) => _ids.contains(id);

  /// 覆写选区。
  void select(Iterable<String> ids) {
    _ids
      ..clear()
      ..addAll(ids);
    notifyListeners();
  }

  /// 切换单个元素选中态。
  void toggle(String id) {
    if (_ids.contains(id)) {
      _ids.remove(id);
    } else {
      _ids.add(id);
    }
    notifyListeners();
  }

  /// 追加单个元素。
  void add(String id) {
    if (_ids.add(id)) {
      notifyListeners();
    }
  }

  /// 移除单个元素。
  void remove(String id) {
    if (_ids.remove(id)) {
      notifyListeners();
    }
  }

  /// 清空选区。
  void clear() {
    if (_ids.isEmpty) {
      return;
    }
    _ids.clear();
    notifyListeners();
  }

  // ---- Wave 3 增量扩展（画布交互：框选 / 批量操作）------------------------

  /// 批量追加元素（单次通知；无新增时不通知）。
  ///
  /// 画布框选（Shift 加选）与粘贴多元素场景使用，避免逐条 [add]
  /// 造成的重复重建。
  void addAll(Iterable<String> ids) {
    bool changed = false;
    for (final String id in ids) {
      if (_ids.add(id)) {
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  /// 批量移除元素（单次通知；无变化时不通知）。
  ///
  /// 批量删除 / 剪贴场景使用，避免逐条 [remove] 造成的重复重建。
  void removeAll(Iterable<String> ids) {
    bool changed = false;
    for (final String id in ids) {
      if (_ids.remove(id)) {
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
    }
  }
}
