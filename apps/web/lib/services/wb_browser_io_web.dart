/// 浏览器 IO（Web 实现）：localStorage 持久化 + 文本文件下载 / 选择。
///
/// 仅 Web 编译（`dart.library.js_interop`）经条件导入接入；全部异常
/// 静默（浏览器隐私模式 / 配额超限 / API 缺失不影响内存画布）。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'wb_canvas_storage.dart';

/// 浏览器 `window.localStorage` 存储。
class WbLocalStorage implements WbCanvasStorage {
  /// 创建浏览器本地存储。
  const WbLocalStorage();

  @override
  String? read(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } catch (_) {
      // 隐私模式 / 存储被禁用：视为无存档。
      return null;
    }
  }

  @override
  void write(String key, String value) {
    try {
      web.window.localStorage.setItem(key, value);
    } catch (_) {
      // 配额超限 / 存储被禁用：静默（内存状态不受影响）。
    }
  }

  @override
  void clear(String key) {
    try {
      web.window.localStorage.removeItem(key);
    } catch (_) {
      // 静默。
    }
  }
}

/// 创建浏览器本地存储。
WbCanvasStorage createWbCanvasStorage() => const WbLocalStorage();

/// 触发浏览器下载文本文件（Blob + 临时 `<a download>`；不阻塞 UI）。
Future<void> wbDownloadTextFile(String fileName, String contents) async {
  final web.Blob blob = web.Blob(
    <JSAny>[contents.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json;charset=utf-8'),
  );
  final String url = web.URL.createObjectURL(blob);
  final web.HTMLAnchorElement anchor =
      web.document.createElement('a') as web.HTMLAnchorElement;
  anchor
    ..href = url
    ..download = fileName
    ..click();
  web.URL.revokeObjectURL(url);
}

/// 弹出文件选择框并读取所选文本（用户取消返回 null）。
///
/// 同时监听 `change` 与 `cancel`（现代浏览器选择框取消会触发
/// `cancel`；旧浏览器取消不触发事件，此时 Future 保持挂起但无副作用）。
Future<String?> wbPickTextFile({
  String accept = '.wbd,application/json',
}) {
  final web.HTMLInputElement input =
      web.document.createElement('input') as web.HTMLInputElement;
  input
    ..type = 'file'
    ..accept = accept;
  final Completer<String?> completer = Completer<String?>();

  void completeOnce(String? value) {
    if (!completer.isCompleted) {
      completer.complete(value);
    }
  }

  input.onchange = (web.Event _) {
    final web.FileList? files = input.files;
    final web.File? file = (files == null || files.length == 0)
        ? null
        : files.item(0);
    if (file == null) {
      completeOnce(null);
      return;
    }
    file.text().toDart.then((JSString text) => completeOnce(text.toDart));
  }.toJS;
  input.oncancel = (web.Event _) {
    completeOnce(null);
  }.toJS;

  input.click();
  return completer.future;
}

/// 弹出文件选择框并读取所选二进制文件（用户取消返回 null）。
///
/// 与 [wbPickTextFile] 同模式（同时监听 `change` / `cancel`），
/// 供「我的组件」导入 SVG / 图片使用。
Future<({String name, Uint8List bytes})?> wbPickBinaryFile({
  String accept = '.svg,image/*',
}) {
  final web.HTMLInputElement input =
      web.document.createElement('input') as web.HTMLInputElement;
  input
    ..type = 'file'
    ..accept = accept;
  final Completer<({String name, Uint8List bytes})?> completer =
      Completer<({String name, Uint8List bytes})?>();

  void completeOnce(({String name, Uint8List bytes})? value) {
    if (!completer.isCompleted) {
      completer.complete(value);
    }
  }

  input.onchange = (web.Event _) {
    final web.FileList? files = input.files;
    final web.File? file = (files == null || files.length == 0)
        ? null
        : files.item(0);
    if (file == null) {
      completeOnce(null);
      return;
    }
    final String name = file.name;
    file.arrayBuffer().toDart.then((JSArrayBuffer buffer) {
      completeOnce((
        name: name,
        bytes: buffer.toDart.asUint8List(),
      ));
    });
  }.toJS;
  input.oncancel = (web.Event _) {
    completeOnce(null);
  }.toJS;

  input.click();
  return completer.future;
}
