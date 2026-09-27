/// `WhiteboardWebPlatform.registerWith` 的 Registrar 真实类型（仅 Web 编译）。
///
/// 直接复用 `flutter_web_plugins` 的 Registrar —— 与 Flutter 工具生成的
/// `web_plugin_registrant.dart` 传入的类型完全一致
/// （《Flutter + C++ 工程结构设计》§6.4）。
library;

export 'package:flutter_web_plugins/flutter_web_plugins.dart' show Registrar;
