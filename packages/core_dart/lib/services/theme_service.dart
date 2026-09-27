import 'dart:convert';

import '../models/theme.dart';
import '../utils/json_codec.dart';
import '../wb_core_ffi.dart';

/// 主题服务：当前 / 列表 / 加载（theme 域）。
///
/// 注意：`wb_theme_load` 的入参即"主题本身"——内置主题传 JSON 字符串
/// `"dark-night"`，自定义主题传完整对象（含 `colors`）。不要传 `{id: ...}`
/// 包裹（引擎不会拆包）。
class WbThemeService {
  const WbThemeService(this.ffi);

  final WbCoreFfi ffi;

  /// 当前主题（引擎返回 `{theme: {...}}`，此处解包）。
  WbThemeSpec current() {
    final WbResponse response =
        WbResponse.parse(ffi.call0(ffi.bindings.wbThemeCurrent));
    return WbThemeSpec.fromJson(
      WbJsonCodec.unwrap(response.requireResult(), 'theme'),
    );
  }

  /// 全部内置主题。
  List<WbThemeSpec> list() {
    final WbResponse response =
        WbResponse.parse(ffi.call0(ffi.bindings.wbThemeList));
    final Map<String, dynamic> result = response.requireResult();
    return WbThemeSpec.listFromJson(result['themes'] ?? result['items']);
  }

  /// 按 id 应用内置主题（如 `clean-professional`）。
  WbThemeSpec applyById(String themeId) =>
      loadJson(jsonEncode(themeId));

  /// 应用自定义主题（对象须含 `colors`；缺省时引擎补 id/name/dark）。
  WbThemeSpec load(Map<String, dynamic> theme) =>
      loadJson(WbJsonCodec.encode(theme));

  /// 原始 JSON 入参直通（字符串 id 或主题对象，见类注释）。
  WbThemeSpec loadJson(String themeJson) {
    final WbResponse response = WbResponse.parse(
      ffi.call1(ffi.bindings.wbThemeLoad, themeJson),
    );
    return WbThemeSpec.fromJson(
      WbJsonCodec.unwrap(response.requireResult(), 'theme'),
    );
  }
}
