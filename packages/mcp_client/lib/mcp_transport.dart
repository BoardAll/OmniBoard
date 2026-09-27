/// MCP 传输抽象（《MCP Server 详细设计》§4 / §11.9）。
library;

import 'dart:async';

/// 传输层抽象：请求 / 响应模式的消息信道。
///
/// 具体实现见：
/// - `McpStdioTransport`：本地进程 stdin/stdout
/// - `McpSseTransport`：SSE 事件流 + HTTP POST
/// - `McpHttpTransport`：Streamable HTTP 单端点
abstract class McpTransport {
  /// 入站消息流（每项为一条完整 JSON-RPC 文本消息）。
  Stream<String> get messages;

  /// 传输层错误流（连接中断 / 解析失败等）。
  Stream<Object> get errors;

  /// 传输是否运行中。
  bool get isRunning;

  /// 启动传输（建立连接 / 拉起进程）。
  Future<void> start();

  /// 停止传输（关闭连接 / 终止进程），可重复调用。
  Future<void> stop();

  /// 发送一条 JSON-RPC 文本消息（fire-and-forget）。
  void send(String message);
}

/// 传输层公共实现：消息 / 错误广播流管理。
abstract class McpTransportBase implements McpTransport {
  final StreamController<String> _messages =
      StreamController<String>.broadcast(sync: true);
  final StreamController<Object> _errors =
      StreamController<Object>.broadcast(sync: true);

  bool _running = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  bool get isRunning => _running;

  /// 子类置位运行状态。
  void setRunning(bool value) => _running = value;

  /// 子类推入一条入站消息。
  void emitMessage(String message) {
    if (!_messages.isClosed) {
      _messages.add(message);
    }
  }

  /// 子类推入一个错误。
  void emitError(Object error) {
    if (!_errors.isClosed) {
      _errors.add(error);
    }
  }

  /// 关闭流。
  Future<void> closeStreams() async {
    await _messages.close();
    await _errors.close();
  }

  @override
  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
  }
}

/// SSE 行级解码器：将 `LineSplitter` 输出还原为完整事件。
///
/// 对每一行调用 [addLine]；完整事件（以空行分隔）通过 [onEvent] 回调输出。
class McpSseDecoder {
  McpSseDecoder({required this.onEvent});

  /// 事件回调：`event` 为事件名（缺省为空字符串），`data` 为多行数据合并值。
  final void Function(String event, String data) onEvent;

  String _currentEvent = '';
  final List<String> _dataLines = <String>[];

  /// 输入一行原始 SSE 文本。
  void addLine(String line) {
    if (line.isEmpty) {
      _dispatch();
      return;
    }
    if (line.startsWith(':')) {
      return; // 注释行。
    }
    if (line.startsWith('event:')) {
      _currentEvent = line.substring(6).trim();
      return;
    }
    if (line.startsWith('data:')) {
      _dataLines.add(line.substring(5).trimLeft());
    }
  }

  void _dispatch() {
    final String event = _currentEvent;
    final String data = _dataLines.join('\n');
    _currentEvent = '';
    _dataLines.clear();
    if (data.isEmpty) {
      return;
    }
    onEvent(event, data);
  }
}
