import '../engine.dart';
import '../models/page.dart';
import '../utils/json_codec.dart';

/// 页面服务：列表 / 增删改 / 排序 / 背景 / 锁定隐藏。
class WbPageService {
  const WbPageService(this.ffi);

  final WbEngineCaller ffi;

  /// 页面列表（按白板 boardId）。
  List<WbPage> list(String boardId) {
    final WbResponse response =
        WbResponse.parse(ffi.call1('wb_page_list', boardId));
    final Map<String, dynamic> result = response.requireResult();
    final List<Map<String, dynamic>> pagesList =
        WbJsonCodec.extractList(result['pages'] ?? result['items']);
    return pagesList.map(WbPage.fromJson).toList();
  }

  /// 创建页面（[options] 可含 `name` / `background`）。
  WbPage create(String boardId, [Map<String, dynamic> options = const {}]) {
    final WbResponse response = WbResponse.parse(
      ffi.call2(
        'wb_page_create',
        boardId,
        WbJsonCodec.encode(options),
      ),
    );
    return WbPage.fromJson(WbJsonCodec.unwrap(response.requireResult(), 'page'));
  }

  /// 复制页面。
  WbPage duplicate(String pageId) {
    final WbResponse response =
        WbResponse.parse(ffi.call1('wb_page_duplicate', pageId));
    return WbPage.fromJson(WbJsonCodec.unwrap(response.requireResult(), 'page'));
  }

  /// 删除页面（返回删除结果 JSON）。
  Map<String, dynamic> delete(String pageId) {
    final WbResponse response =
        WbResponse.parse(ffi.call1('wb_page_delete', pageId));
    return response.requireResult();
  }

  /// 移动页面到新索引。
  Map<String, dynamic> move(String pageId, int newIndex) {
    final WbResponse response = WbResponse.parse(
      ffi.call1Int('wb_page_move', pageId, newIndex),
    );
    return response.requireResult();
  }

  /// 重命名页面。
  WbPage rename(String pageId, String name) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_page_rename', pageId, name),
    );
    return WbPage.fromJson(WbJsonCodec.unwrap(response.requireResult(), 'page'));
  }

  /// 设置页面背景（preset 或完整 background 对象，见 background_service）。
  Map<String, dynamic> setBackground(
    String pageId,
    Map<String, dynamic> background,
  ) {
    final WbResponse response = WbResponse.parse(
      ffi.call2(
        'wb_page_set_background',
        pageId,
        WbJsonCodec.encode(background),
      ),
    );
    return response.requireResult();
  }

  /// 锁定 / 解锁页面。
  Map<String, dynamic> lock(String pageId, bool locked) {
    final WbResponse response = WbResponse.parse(
      ffi.call1Int('wb_page_lock', pageId, locked ? 1 : 0),
    );
    return response.requireResult();
  }

  /// 隐藏 / 显示页面。
  Map<String, dynamic> hide(String pageId, bool hidden) {
    final WbResponse response = WbResponse.parse(
      ffi.call1Int('wb_page_hide', pageId, hidden ? 1 : 0),
    );
    return response.requireResult();
  }
}
