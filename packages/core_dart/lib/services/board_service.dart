import '../engine.dart';
import '../models/board.dart';
import '../utils/json_codec.dart';

/// 白板服务：生命周期 + 命令/工具执行入口。
class WbBoardService {
  const WbBoardService(this.ffi);

  final WbEngineCaller ffi;

  /// 创建白板并返回引擎句柄（uint64）。
  ///
  /// [firstPage] 可直接给出首屏页面选项（如 `{'name': '页面 1'}` 或含
  /// `background` 的对象）；缺省时引擎自动创建"页面 1"。
  int create({String name = '未命名白板', Map<String, dynamic>? firstPage}) {
    final String payload = WbJsonCodec.encode(<String, dynamic>{
      'name': name,
      if (firstPage != null) 'page': firstPage,
    });
    return ffi.callU64('wb_create_board', payload);
  }

  /// 销毁白板（句柄失效）。
  void destroy(int handle) => ffi.callVoidHandle('wb_destroy_board', handle);

  /// 读取白板完整快照（引擎返回 `{board: {...}}`，此处解包）。
  WbBoard get(int handle) {
    final WbResponse response =
        WbResponse.parse(ffi.callHandle('wb_board_get', handle));
    final Map<String, dynamic> result = response.requireResult();
    return WbBoard.fromJson(WbJsonCodec.unwrap(result, 'board'));
  }

  /// 执行一条命令（命令总线 JSON，见 command.schema.json）。
  Map<String, dynamic> executeCommand(
    int handle,
    Map<String, dynamic> command,
  ) {
    final WbResponse response = WbResponse.parse(
      ffi.callHandle1(
        'wb_execute_command',
        handle,
        WbJsonCodec.encode(command),
      ),
    );
    return response.requireResult();
  }

  /// 执行工具（tool registry JSON；返回工具执行结果）。
  Map<String, dynamic> executeTool(
    String toolId, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final WbResponse response = WbResponse.parse(
      ffi.call2('wb_execute_tool', toolId, WbJsonCodec.encode(args)),
    );
    return response.requireResult();
  }

  /// 撤销 / 重做快捷方式（命令总线 `command.undo` / `command.redo`）。
  Map<String, dynamic> undo(int handle) => executeCommand(
        handle,
        <String, dynamic>{'type': 'command.undo', 'params': <String, dynamic>{}},
      );

  Map<String, dynamic> redo(int handle) => executeCommand(
        handle,
        <String, dynamic>{'type': 'command.redo', 'params': <String, dynamic>{}},
      );
}
