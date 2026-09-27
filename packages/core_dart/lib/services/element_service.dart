import 'dart:convert';

import '../models/element.dart';
import '../utils/json_codec.dart';
import '../wb_core_ffi.dart';

/// 元素服务：创建 / 更新 / 删除 / 查询 / 批量操作。
class WbElementService {
  const WbElementService(this.ffi);

  final WbCoreFfi ffi;

  /// 元素列表（按页面 pageId）。
  List<WbElement> list(String pageId) {
    final WbResponse response =
        WbResponse.parse(ffi.call1(ffi.bindings.wbElementList, pageId));
    final Map<String, dynamic> result = response.requireResult();
    final List<Map<String, dynamic>> items =
        WbJsonCodec.extractList(result['elements'] ?? result['items']);
    return items.map(WbElement.fromJson).toList();
  }

  /// 创建元素（[element] 为完整元素 JSON，服务端补齐 id/时间戳）。
  WbElement create(String pageId, Map<String, dynamic> element) {
    final WbResponse response = WbResponse.parse(
      ffi.call2(
        ffi.bindings.wbElementCreate,
        pageId,
        WbJsonCodec.encode(element),
      ),
    );
    return WbElement.fromJson(
      WbJsonCodec.unwrap(response.requireResult(), 'element'),
    );
  }

  /// 更新元素（[patch] 局部字段）。
  WbElement update(String elementId, Map<String, dynamic> patch) {
    final WbResponse response = WbResponse.parse(
      ffi.call2(
        ffi.bindings.wbElementUpdate,
        elementId,
        WbJsonCodec.encode(patch),
      ),
    );
    return WbElement.fromJson(
      WbJsonCodec.unwrap(response.requireResult(), 'element'),
    );
  }

  /// 删除元素。
  Map<String, dynamic> delete(String elementId) {
    final WbResponse response =
        WbResponse.parse(ffi.call1(ffi.bindings.wbElementDelete, elementId));
    return response.requireResult();
  }

  /// 批量操作（单事务；`ops` 为操作数组，任一步失败整体回滚）。
  ///
  /// C ABI `wb_element_batch(pageId, opsJson)` 要求 opsJson 为顶层数组
  /// （引擎侧 `args.ops.is_array()` 校验），故此处直接编码 [ops]。
  Map<String, dynamic> batch(String pageId, List<Map<String, dynamic>> ops) {
    final WbResponse response = WbResponse.parse(
      ffi.call2(
        ffi.bindings.wbElementBatch,
        pageId,
        jsonEncode(ops),
      ),
    );
    return response.requireResult();
  }
}
