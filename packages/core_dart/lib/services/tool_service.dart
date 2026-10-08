import '../engine.dart';
import '../models/tool.dart';
import '../utils/json_codec.dart';

/// 工具服务：工具注册表（list/get/execute）+ 工具栏上下文（toolbar 域）。
class WbToolService {
  const WbToolService(this.ffi);

  final WbEngineCaller ffi;

  /// 全部工具描述。
  List<WbTool> list() {
    final WbResponse response =
        WbResponse.parse(ffi.call0('wb_tool_list'));
    return WbTool.listFromJson(response.requireResult()['tools']);
  }

  /// 单个工具（含参数 schema）。
  WbToolSchema get(String toolId) {
    final WbResponse response =
        WbResponse.parse(ffi.call1('wb_tool_get', toolId));
    return WbToolSchema.fromJson(
      WbJsonCodec.unwrap(response.requireResult(), 'tool'),
    );
  }

  /// 执行工具（toolId + args JSON）。
  Map<String, dynamic> execute(
    String toolId, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_execute_tool', toolId, WbJsonCodec.encode(args)),
    );
    return response.requireResult();
  }

  /// 工具栏模型（全部工具按钮 + 分组）。
  Map<String, dynamic> toolbarList() {
    final WbResponse response =
        WbResponse.parse(ffi.call0('wb_toolbar_list'));
    return response.requireResult();
  }

  /// 按选中元素计算上下文工具栏（ContextResolver）。
  Map<String, dynamic> toolbarContext(List<String> elementIds) {
    final WbResponse response = WbResponse.parse(
      ffi.call1(
        'wb_toolbar_context',
        WbJsonCodec.encode(<String, dynamic>{'elementIds': elementIds}),
      ),
    );
    return response.requireResult();
  }

  /// 调用上下文工具（工具栏按钮 → 工具执行）。
  Map<String, dynamic> toolbarInvoke(
    String toolId, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final WbResponse response = WbResponse.parse(
      ffi.call2(
        'wb_toolbar_invoke',
        toolId,
        WbJsonCodec.encode(args),
      ),
    );
    return response.requireResult();
  }
}
