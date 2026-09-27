import '../utils/json_codec.dart';
import '../wb_core_ffi.dart';

/// 渲染服务：显示列表 / 脏区 / 3D / 缩略图 / 缓存与性能统计（render 域）。
class WbRenderService {
  const WbRenderService(this.ffi);

  final WbCoreFfi ffi;

  /// 取某画板（句柄）指定图层的显示列表。
  Map<String, dynamic> displayList(int handle, [int layer = 0]) {
    final WbResponse response = WbResponse.parse(
      ffi.callHandleInt(ffi.bindings.wbGetDisplayList, handle, layer),
    );
    return response.requireResult();
  }

  /// 按页面渲染显示列表。
  Map<String, dynamic> renderDisplayList(String pageId, [int layer = 0]) {
    final WbResponse response = WbResponse.parse(
      ffi.call1Int(ffi.bindings.wbRenderDisplayList, pageId, layer),
    );
    return response.requireResult();
  }

  /// 渲染脏区（`{'x':..,'y':..,'width':..,'height':..}` 或元素 id 列表）。
  Map<String, dynamic> renderDirty(
    String pageId, [
    Map<String, dynamic> dirty = const <String, dynamic>{},
  ]) {
    final WbResponse response = WbResponse.parse(
      ffi.call2(
        ffi.bindings.wbRenderDirty,
        pageId,
        WbJsonCodec.encode(dirty),
      ),
    );
    return response.requireResult();
  }

  /// 渲染 3D 元素到指定视口。
  Map<String, dynamic> render3d(
    int handle,
    String elementId, [
    int width = 0,
    int height = 0,
  ]) {
    final WbResponse response = WbResponse.parse(
      ffi.callHandle1Int2(
        ffi.bindings.wbRender3d,
        handle,
        elementId,
        width,
        height,
      ),
    );
    return response.requireResult();
  }

  /// 页面缩略图（宽高 0 表示引擎默认尺寸）。
  Map<String, dynamic> thumbnail(
    String pageId, [
    int width = 0,
    int height = 0,
  ]) {
    final WbResponse response = WbResponse.parse(
      ffi.call1Int2(ffi.bindings.wbRenderThumbnail, pageId, width, height),
    );
    return response.requireResult();
  }

  /// 渲染缓存统计。
  Map<String, dynamic> cacheStats() {
    final WbResponse response =
        WbResponse.parse(ffi.call0(ffi.bindings.wbRenderCacheStats));
    return response.requireResult();
  }

  /// 清空渲染缓存。
  Map<String, dynamic> cacheClear() {
    final WbResponse response =
        WbResponse.parse(ffi.call0(ffi.bindings.wbRenderCacheClear));
    return response.requireResult();
  }

  /// 性能统计（帧时间等）。
  Map<String, dynamic> perfStats() {
    final WbResponse response =
        WbResponse.parse(ffi.call0(ffi.bindings.wbRenderPerfStats));
    return response.requireResult();
  }
}
