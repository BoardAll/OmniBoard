/// 白板文件服务：保存 / 另存为 / 打开 / 最近列表 / 未保存脏标记。
///
/// 监听画布文档修订号（[WbCanvasController.documentRevision]）、页面状态与
/// 白板状态的变更通知，维护 [hasUnsavedChanges]；保存 / 打开流程全程
/// try/catch（失败返回带文案的失败结果，不抛出）。
///
/// 文件对话框经 [openFilePicker] / [saveFilePicker] 注入（缺省走
/// `whiteboard_windows` 原生对话框；测试注入假实现）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:whiteboard_core/wb_core.dart';
import 'package:whiteboard_windows/whiteboard_windows.dart';

import '../state/board_state.dart';
import '../state/page_state.dart';
import '../widgets/canvas/canvas_controller.dart';
import '../widgets/canvas/canvas_model.dart';
import 'board_file_codec.dart';
import 'settings_store.dart';

/// 打开文件选择器（返回 null = 用户取消）。
typedef WbOpenFilePicker = Future<String?> Function();

/// 保存文件选择器（返回 null = 用户取消）。
typedef WbSaveFilePicker = Future<String?> Function({String suggestedPath});

/// 保存结果状态。
enum WbSaveStatus {
  /// 已写入磁盘。
  saved,

  /// 用户在另存为对话框取消。
  cancelled,

  /// 写入失败（message 携带原因）。
  failed,
}

/// 保存结果。
class WbSaveOutcome {
  const WbSaveOutcome._(this.status, this.message);

  factory WbSaveOutcome.saved(String path) =>
      WbSaveOutcome._(WbSaveStatus.saved, path);

  factory WbSaveOutcome.cancelled() =>
      const WbSaveOutcome._(WbSaveStatus.cancelled, '');

  factory WbSaveOutcome.failed(String message) =>
      WbSaveOutcome._(WbSaveStatus.failed, message);

  /// 状态。
  final WbSaveStatus status;

  /// 附加信息（saved = 文件路径；failed = 原因；cancelled = 空串）。
  final String message;

  /// 是否已保存。
  bool get isSaved => status == WbSaveStatus.saved;
}

/// 打开结果状态。
enum WbOpenStatus {
  /// 已载入内存。
  opened,

  /// 用户在对话框取消。
  cancelled,

  /// 读取 / 解析失败（message 携带原因）。
  failed,
}

/// 打开结果。
class WbOpenOutcome {
  const WbOpenOutcome._(this.status, this.message);

  factory WbOpenOutcome.opened(String path) =>
      WbOpenOutcome._(WbOpenStatus.opened, path);

  factory WbOpenOutcome.cancelled() =>
      const WbOpenOutcome._(WbOpenStatus.cancelled, '');

  factory WbOpenOutcome.failed(String message) =>
      WbOpenOutcome._(WbOpenStatus.failed, message);

  /// 状态。
  final WbOpenStatus status;

  /// 附加信息（opened = 文件路径；failed = 原因；cancelled = 空串）。
  final String message;

  /// 是否已打开。
  bool get isOpened => status == WbOpenStatus.opened;
}

/// 打开本地白板的路由附加参数（`state.extra` 类型）。
class WbBoardOpenRequest {
  const WbBoardOpenRequest(this.filePath);

  /// 待打开的 `.wbd` 文件路径。
  final String filePath;
}

/// 白板文件服务（应用级单例，经 Provider 下发）。
class WbBoardFileService extends ChangeNotifier {
  WbBoardFileService({
    WbSettingsStore? settings,
    this.openFilePicker = _defaultOpenPicker,
    this.saveFilePicker = _defaultSavePicker,
  }) : _settings = settings;

  /// 缺省打开选择器：Windows 原生对话框（通道缺失返回 null）。
  static Future<String?> _defaultOpenPicker() =>
      WindowsWindowPlugin().openBoardFile();

  /// 缺省保存选择器：Windows 原生对话框（通道缺失返回 null）。
  static Future<String?> _defaultSavePicker({String suggestedPath = ''}) =>
      WindowsWindowPlugin().saveBoardFile(suggestedPath: suggestedPath);

  final WbSettingsStore? _settings;

  /// 打开文件选择器（可注入）。
  final WbOpenFilePicker openFilePicker;

  /// 保存文件选择器（可注入）。
  final WbSaveFilePicker saveFilePicker;

  WbBoardState? _board;
  WbPageState? _pages;
  WbCanvasController? _canvas;
  int _lastRevision = 0;
  bool _suspended = false;

  String _filePath = '';
  bool _hasUnsavedChanges = false;

  /// 当前文件路径（空串 = 从未保存过）。
  String get filePath => _filePath;

  /// 是否有未保存改动。
  bool get hasUnsavedChanges => _hasUnsavedChanges;

  /// 是否已绑定白板（可保存 / 可判脏）。
  bool get isBound => _canvas != null;

  /// 最近打开的白板（最新在前；未挂载设置存储时为空）。
  List<WbRecentBoardEntry> get recentBoards =>
      _settings?.recentBoards ?? const <WbRecentBoardEntry>[];

  /// 当前文件展示名（文件名；未保存过返回空串）。
  String get fileDisplayName {
    if (_filePath.isEmpty) {
      return '';
    }
    final int index = _filePath.lastIndexOf(RegExp(r'[\\/]'));
    return index < 0 ? _filePath : _filePath.substring(index + 1);
  }

  // ---------------------------------------------------------------------------
  // 绑定 / 解绑
  // ---------------------------------------------------------------------------

  /// 绑定白板三源并重置为干净基线（新建 / 打开后调用）。
  ///
  /// 重置 [filePath] 为空、[hasUnsavedChanges] 为 false：新建流程在
  /// `attach` 之后绑定，加载过程中的通知不误标脏。
  void bindBoard({
    required WbBoardState board,
    required WbPageState pages,
    required WbCanvasController canvas,
  }) {
    unbind();
    _board = board;
    _pages = pages;
    _canvas = canvas;
    _lastRevision = canvas.documentRevision;
    board.addListener(_markDirty);
    pages.addListener(_markDirty);
    canvas.addListener(_onCanvasNotify);
    _filePath = '';
    _hasUnsavedChanges = false;
    notifyListeners();
  }

  /// 解绑（编辑页 dispose 调用；不通知，避免销毁期重建）。
  void unbind() {
    _board?.removeListener(_markDirty);
    _pages?.removeListener(_markDirty);
    _canvas?.removeListener(_onCanvasNotify);
    _board = null;
    _pages = null;
    _canvas = null;
    _filePath = '';
    _hasUnsavedChanges = false;
  }

  void _onCanvasNotify() {
    final WbCanvasController? canvas = _canvas;
    if (canvas == null) {
      return;
    }
    final int revision = canvas.documentRevision;
    if (revision == _lastRevision) {
      return;
    }
    _lastRevision = revision;
    _markDirty();
  }

  void _markDirty() {
    if (_suspended || _hasUnsavedChanges) {
      return;
    }
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 保存
  // ---------------------------------------------------------------------------

  /// 保存白板（[saveAs] 或从未保存过时弹另存为对话框）。
  ///
  /// 返回 saved（带路径）/ cancelled / failed（带原因）；不抛异常。
  Future<WbSaveOutcome> save({bool saveAs = false}) async {
    final WbBoardState? board = _board;
    final WbPageState? pages = _pages;
    final WbCanvasController? canvas = _canvas;
    if (board == null || pages == null || canvas == null) {
      return WbSaveOutcome.failed('白板未就绪，无法保存');
    }
    // 提交编辑中的文本（若有），保证落盘内容与所见一致。
    canvas.endTextEditing();

    String target = _filePath;
    if (target.isEmpty || saveAs) {
      final String suggested =
          suggestedSavePath(board.board?.name ?? pages.boardId);
      final String? picked = await saveFilePicker(suggestedPath: suggested);
      if (picked == null || picked.isEmpty) {
        return WbSaveOutcome.cancelled();
      }
      target = ensureWbdExtension(picked);
    }

    try {
      final String content = WbBoardFileCodec.encode(_assemble(board, pages, canvas));
      final File file = File(target);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content, flush: true);
    } catch (e) {
      return WbSaveOutcome.failed('保存失败：$e');
    }

    _filePath = target;
    _hasUnsavedChanges = false;
    _lastRevision = canvas.documentRevision;
    _rememberRecent(target, board.board?.name ?? '');
    notifyListeners();
    return WbSaveOutcome.saved(target);
  }

  /// 装配内存态为白板数据（页面 + 各页元素快照）。
  WbBoardData _assemble(
    WbBoardState board,
    WbPageState pages,
    WbCanvasController canvas,
  ) {
    return WbBoardData(
      boardId: board.board?.id ?? pages.boardId,
      boardName: board.board?.name ?? '',
      currentPageId: pages.currentPageId,
      pages: <WbBoardPageData>[
        for (final WbPage page in pages.pages)
          WbBoardPageData(
            id: page.id,
            name: page.name,
            locked: page.locked,
            hidden: page.hidden,
            background: page.background.isEmpty ? null : page.background,
            elements: canvas.document.snapshot(page.id),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 打开
  // ---------------------------------------------------------------------------

  /// 弹文件对话框选择并打开本地白板。
  Future<WbOpenOutcome> openWithDialog() async {
    final String? path = await openFilePicker();
    if (path == null || path.isEmpty) {
      return WbOpenOutcome.cancelled();
    }
    return openPath(path);
  }

  /// 打开指定 `.wbd` 文件并应用内存态。
  ///
  /// 返回 opened（带路径）/ cancelled / failed（带原因）；不抛异常。
  Future<WbOpenOutcome> openPath(String path) async {
    final WbBoardState? board = _board;
    final WbPageState? pages = _pages;
    final WbCanvasController? canvas = _canvas;
    if (board == null || pages == null || canvas == null) {
      return WbOpenOutcome.failed('白板未就绪，无法打开文件');
    }

    final String content;
    try {
      final File file = File(path);
      if (!file.existsSync()) {
        return WbOpenOutcome.failed('文件不存在：$path');
      }
      content = file.readAsStringSync();
    } catch (e) {
      return WbOpenOutcome.failed('读取文件失败：$e');
    }

    final WbBoardData data;
    try {
      data = WbBoardFileCodec.decode(content);
    } on FormatException catch (e) {
      return WbOpenOutcome.failed('无法打开：${e.message}');
    } catch (e) {
      return WbOpenOutcome.failed('文件解析失败：$e');
    }

    final String boardId =
        data.boardId.isEmpty ? 'board-local' : data.boardId;
    final List<WbPage> pageModels = <WbPage>[
      for (final WbBoardPageData page in data.pages)
        WbPage(
          id: page.id,
          name: page.name,
          locked: page.locked,
          hidden: page.hidden,
          background: page.background ?? const <String, dynamic>{},
          elementCount: page.elements.length,
        ),
    ];

    // 屏蔽加载过程中的通知自触发（board/pages/canvas 均会通知）。
    _suspended = true;
    try {
      board.loadBoard(WbBoard(
        id: boardId,
        name: data.boardName,
        pages: pageModels,
      ));
      pages.restore(
        boardId: boardId,
        pages: pageModels,
        currentPageId: data.currentPageId,
      );
      canvas.loadBoardData(<String, List<WbCanvasElement>>{
        for (final WbBoardPageData page in data.pages)
          page.id: page.elements,
      });
      canvas.setPage(pages.currentPageId);
    } finally {
      _suspended = false;
    }

    _filePath = path;
    _hasUnsavedChanges = false;
    _lastRevision = canvas.documentRevision;
    _rememberRecent(path, data.boardName);
    notifyListeners();
    return WbOpenOutcome.opened(path);
  }

  // ---------------------------------------------------------------------------
  // 最近列表
  // ---------------------------------------------------------------------------

  /// 记录到最近列表（设置存储不可用时 no-op）。
  void _rememberRecent(String path, String name) {
    _settings?.rememberBoard(path: path, name: name);
  }

  /// 从最近列表移除（失效路径清理）。
  void removeRecentBoard(String path) {
    _settings?.removeRecentBoard(path);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 路径工具
  // ---------------------------------------------------------------------------

  /// 补齐 `.wbd` 后缀（无后缀或其它后缀时追加）。
  static String ensureWbdExtension(String path) =>
      path.toLowerCase().endsWith('.wbd') ? path : '$path.wbd';

  /// 建议保存路径：`%USERPROFILE%\Documents\Whiteboard\<板名>.wbd`。
  ///
  /// Documents 目录不存在时回退 `%USERPROFILE%`；均不可解析时仅文件名。
  static String suggestedSavePath(String boardName) {
    final String resolved =
        boardName.trim().isEmpty ? '未命名白板' : boardName.trim();
    final String safe = _sanitizeFileName(resolved);
    final String profile = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    if (profile.isEmpty) {
      return '$safe.wbd';
    }
    final String separator = Platform.isWindows ? '\\' : '/';
    final Directory documents = Directory('$profile${separator}Documents');
    final String dir = documents.existsSync()
        ? '${documents.path}${separator}Whiteboard'
        : profile;
    return '$dir$separator$safe.wbd';
  }

  /// 文件名安全化（去掉 Windows 非法字符并限长）。
  static String _sanitizeFileName(String name) {
    final String cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    final String trimmed = cleaned.trim();
    if (trimmed.isEmpty) {
      return '未命名白板';
    }
    return trimmed.length > 80 ? trimmed.substring(0, 80) : trimmed;
  }
}
