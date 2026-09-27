/// Web 应用入口。
///
/// 启动即渲染列表页；WASM 核心在进入编辑页时按需加载
/// （见 `services/wb_core_service.dart` / `pages/board_edit_page.dart`）。
library;

import 'package:flutter/material.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WhiteboardWebApp());
}
