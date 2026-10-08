/// 浏览器 IO（桩实现：非 Web 环境 / VM 测试）。
///
/// 与 Web 实现同形：存储为进程内 Map（经 [createWbCanvasStorage] 共享
/// 单例，语义接近 localStorage 的全局单份），下载为 no-op、文件选择
/// 恒返回 null，均不抛异常。
library;

import 'dart:typed_data';

import 'wb_canvas_storage.dart';

/// 进程内内存存储（桩）。
class WbMemoryCanvasStorage implements WbCanvasStorage {
  /// 创建内存存储。
  WbMemoryCanvasStorage();

  final Map<String, String> _data = <String, String>{};

  /// 当前存档键集合（诊断 / 测试用）。
  Iterable<String> get keys => _data.keys;

  @override
  String? read(String key) => _data[key];

  @override
  void write(String key, String value) => _data[key] = value;

  @override
  void clear(String key) => _data.remove(key);
}

WbCanvasStorage? _shared;

/// 创建（共享）内存存储：多次调用返回同一实例。
WbCanvasStorage createWbCanvasStorage() =>
    _shared ??= WbMemoryCanvasStorage();

/// 桩：非 Web 环境无下载能力（no-op）。
Future<void> wbDownloadTextFile(String fileName, String contents) async {}

/// 桩：非 Web 环境无文件选择（恒返回 null）。
Future<String?> wbPickTextFile({
  String accept = '.wbd,application/json',
}) async =>
    null;

/// 桩：非 Web 环境无二进制文件选择（恒返回 null）。
Future<({String name, Uint8List bytes})?> wbPickBinaryFile({
  String accept = '.svg,image/*',
}) async =>
    null;
