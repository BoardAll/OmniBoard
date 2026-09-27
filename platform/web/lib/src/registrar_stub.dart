/// `WhiteboardWebPlatform.registerWith` 的 Registrar 占位类型（非 Web 编译）。
///
/// `flutter_web_plugins` 依赖 `dart:ui_web`，在 Windows VM
/// （`flutter test` / 桌面宿主）上不可编译；条件导入本占位类型后，
/// 非 Web 目标的 `registerWith` 保持同一 API 形状但不引用该依赖。
///
/// 占位 [Registrar] 永远不会被实例化：插件注册仅在 Web 平台由
/// Flutter 工具生成的 `web_plugin_registrant.dart` 调用。
library;

/// 非 Web 平台的 Registrar 占位类型（API 形状占位，无实际能力）。
class Registrar {
  /// 占位构造（非 Web 环境不会调用）。
  const Registrar();
}
