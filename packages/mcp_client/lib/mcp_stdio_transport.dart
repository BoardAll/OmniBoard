/// MCP stdio 传输（《MCP Server 详细设计》§4.1）。
///
/// 客户端 <--stdin/stdout--> MCP Server 进程；消息为换行分隔的 JSON-RPC。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_transport.dart';

/// 以子进程 stdin/stdout 通信的 stdio 传输。
///
/// ```dart
/// final transport = McpStdioTransport(
///   command: 'whiteboard-mcp',
///   arguments: ['--board', 'board_123'],
///   environment: {'WB_API_KEY': 'wbp_xxx'},
/// );
/// ```
class McpStdioTransport extends McpTransportBase {
  McpStdioTransport({
    required this.command,
    this.arguments = const <String>[],
    this.environment,
    this.workingDirectory,
  });

  final String command;
  final List<String> arguments;

  /// 额外环境变量（如 `WB_API_KEY` / `WB_BOARD_ID`）。
  final Map<String, String>? environment;
  final String? workingDirectory;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  /// 半行缓冲（按 `\n` 分帧）。
  final StringBuffer _buffer = StringBuffer();

  /// 最近一次 stderr 输出（便于诊断）。
  final StringBuffer stderrLog = StringBuffer();

  @override
  Future<void> start() async {
    if (isRunning) {
      return;
    }
    final Process process = await Process.start(
      command,
      arguments,
      environment: environment,
      workingDirectory: workingDirectory,
    );
    _process = process;
    setRunning(true);

    _stdoutSub = process.stdout.transform(utf8.decoder).listen(_onStdoutChunk);
    _stderrSub = process.stderr.transform(utf8.decoder).listen((String chunk) {
      stderrLog.write(chunk);
    });

    unawaited(process.exitCode.then((int code) {
      if (isRunning) {
        setRunning(false);
        emitError(ProcessException(
          command,
          arguments,
          'MCP stdio process exited with code $code',
        ));
      }
    }));
  }

  /// 处理 stdout 分片，按新行分帧后逐条推送。
  void _onStdoutChunk(String chunk) {
    _buffer.write(chunk);
    String buffered = _buffer.toString();
    int newlineIndex = buffered.indexOf('\n');
    while (newlineIndex >= 0) {
      final String line = buffered.substring(0, newlineIndex).trim();
      buffered = buffered.substring(newlineIndex + 1);
      if (line.isNotEmpty) {
        emitMessage(line);
      }
      newlineIndex = buffered.indexOf('\n');
    }
    _buffer
      ..clear()
      ..write(buffered);
  }

  @override
  void send(String message) {
    final Process? process = _process;
    if (process == null || !isRunning) {
      throw StateError('stdio transport is not running');
    }
    process.stdin.writeln(message);
  }

  @override
  Future<void> stop() async {
    if (!isRunning) {
      return;
    }
    setRunning(false);
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    final Process? process = _process;
    if (process != null) {
      try {
        await process.stdin.close();
      } catch (_) {
        // stdin 可能已关闭。
      }
      // 宽限等待，超时后强制终止。
      final bool exited = await process.exitCode
          .timeout(const Duration(seconds: 3), onTimeout: () => -1)
          .then((int code) => code != -1);
      if (!exited) {
        process.kill();
      }
    }
    _process = null;
  }
}
