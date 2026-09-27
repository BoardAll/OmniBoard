/// 白板状态：当前白板生命周期（打开 / 关闭 / 重命名 / 撤销重做）。
library;

import 'package:flutter/foundation.dart';
import 'package:whiteboard_core/wb_core.dart';

import '../services/ffi_service.dart';

/// 白板状态。
///
/// 引擎可用时走 FFI（`wbCreateBoard` / `wbBoardGet` / 命令总线），
/// 否则进入**演示模式**（内存 [WbBoard]，用于无 DLL 的开发/测试环境）。
class WbBoardState extends ChangeNotifier {
  WbBoardState({required this.ffi});

  /// FFI 服务（复用应用级单例）。
  final WbFfiService ffi;

  WbBoard? _board;
  bool _loading = false;
  String _error = '';

  /// 当前白板（未打开返回 null）。
  WbBoard? get board => _board;

  /// 是否已打开白板。
  bool get hasBoard => _board != null;

  /// 是否正在加载。
  bool get isLoading => _loading;

  /// 最近一次错误（空串表示无错误）。
  String get error => _error;

  /// 是否演示模式（无引擎）。
  bool get isDemoMode => !ffi.isAvailable;

  /// 打开（新建）白板 [boardId]。
  ///
  /// 骨架：引擎可用时创建全新白板并读取快照；持久化加载（本地文件 /
  /// 云端恢复）在 Wave 4 接入 —— 届时本方法按 [boardId] 恢复已有内容。
  void open(String boardId, {String name = ''}) {
    _loading = true;
    _error = '';
    notifyListeners();
    try {
      if (ffi.isAvailable) {
        final int handle =
            ffi.board.create(name: name.isEmpty ? '未命名白板' : name);
        _board = ffi.board.get(handle);
      } else {
        _board = WbBoard(
          id: boardId,
          handle: 0,
          name: name.isEmpty ? '演示白板' : name,
          pages: <WbPage>[WbPage(id: '$boardId-page-1', name: '页面 1')],
        );
      }
    } catch (e) {
      _board = null;
      _error = '$e';
    }
    _loading = false;
    notifyListeners();
  }

  /// 从本地文件恢复：销毁旧引擎句柄后采用外部装配的白板对象。
  ///
  /// [board] 由 `board_file_service.dart` 从 `.wbd` 数据装配（handle 恒 0，
  /// 引擎侧不回灌元素——当前 App 本就未注入 FFI store，行为与演示模式
  /// 一致）。失败不抛异常（装配阶段已保证字段完整）。
  void loadBoard(WbBoard board) {
    _loading = true;
    notifyListeners();
    final WbBoard? previous = _board;
    if (previous != null && ffi.isAvailable && previous.handle != 0) {
      try {
        ffi.board.destroy(previous.handle);
      } catch (_) {
        // 句柄可能已失效；忽略。
      }
    }
    _board = board;
    _error = '';
    _loading = false;
    notifyListeners();
  }

  /// 重命名当前白板（骨架：本地更新；引擎侧持久化 Wave 4 接入）。
  void rename(String name) {
    final WbBoard? board = _board;
    if (board == null || name.isEmpty || board.name == name) {
      return;
    }
    _board = board.copyWith(name: name);
    notifyListeners();
  }

  /// 关闭白板并销毁引擎句柄（幂等）。
  void close() {
    final WbBoard? board = _board;
    if (board == null) {
      return;
    }
    if (ffi.isAvailable && board.handle != 0) {
      try {
        ffi.board.destroy(board.handle);
      } catch (_) {
        // 句柄可能已失效；忽略。
      }
    }
    _board = null;
    _error = '';
    notifyListeners();
  }

  /// 撤销（引擎不可用时 no-op）。
  void undo() {
    final WbBoard? board = _board;
    if (board == null || !ffi.isAvailable || board.handle == 0) {
      return;
    }
    ffi.board.undo(board.handle);
    notifyListeners();
  }

  /// 重做（引擎不可用时 no-op）。
  void redo() {
    final WbBoard? board = _board;
    if (board == null || !ffi.isAvailable || board.handle == 0) {
      return;
    }
    ffi.board.redo(board.handle);
    notifyListeners();
  }
}
