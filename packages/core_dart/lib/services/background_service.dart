import '../utils/json_codec.dart';
import '../wb_core_ffi.dart';
import 'page_service.dart';

/// 背景预设描述（对齐 C++ background 域 kPresets）。
class WbBackgroundPreset {
  const WbBackgroundPreset({
    required this.id,
    required this.name,
    required this.type,
    required this.color,
    this.lineColor = '',
    this.spacing = 0,
    this.dark = false,
  });

  final String id;
  final String name;

  /// 类型：solid / dot / grid / lined / squared。
  final String type;
  final String color;
  final String lineColor;

  /// 图案间距（逻辑像素）。
  final int spacing;
  final bool dark;

  /// 转成 `wb_page_set_background` 的 preset 参数。
  Map<String, dynamic> toPresetJson() => <String, dynamic>{'preset': id};

  /// 解析为完整背景对象（镜像 background 域 `PresetToJson` 的存储形态）。
  ///
  /// FFI 无 `wb_background_*` 导出，预设需在客户端解析后经
  /// `wb_page_set_background` 写入（page 域原样存储，不做解析）。
  Map<String, dynamic> toBackgroundJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'pattern': type,
        'baseColor': color,
        'patternColor': lineColor,
        'spacing': spacing,
        'dark': dark,
        'preset': id,
      };

  @override
  String toString() => 'WbBackgroundPreset($id, $name)';
}

/// 背景服务：应用内置预设 / 自定义背景 / 清空（经 page 域转发）。
class WbBackgroundService {
  const WbBackgroundService(this.ffi, [this._pages]);

  final WbCoreFfi ffi;
  final WbPageService? _pages;

  WbPageService get _pageService => _pages ?? WbPageService(ffi);

  /// 11 个内置预设（与 C++ `kPresets` 一一对应）。
  static const List<WbBackgroundPreset> builtinPresets = <WbBackgroundPreset>[
    WbBackgroundPreset(id: 'whiteboard', name: '白板', type: 'solid', color: '#FFFFFF'),
    WbBackgroundPreset(id: 'light-gray', name: '浅灰白板', type: 'solid', color: '#F5F6F8'),
    WbBackgroundPreset(id: 'dot', name: '点阵白板', type: 'dot', color: '#FFFFFF', lineColor: '#D0D5DD', spacing: 20),
    WbBackgroundPreset(id: 'grid', name: '网格白板', type: 'grid', color: '#FFFFFF', lineColor: '#E4E7EC', spacing: 25),
    WbBackgroundPreset(id: 'blackboard', name: '黑板', type: 'solid', color: '#1A1D21', dark: true),
    WbBackgroundPreset(id: 'greenboard', name: '绿板', type: 'solid', color: '#1E3A2F', dark: true),
    WbBackgroundPreset(id: 'cream', name: '米黄护眼', type: 'solid', color: '#FBF3E4'),
    WbBackgroundPreset(id: 'lined', name: '横线纸', type: 'lined', color: '#FFFFFF', lineColor: '#D9DEE8', spacing: 28),
    WbBackgroundPreset(id: 'squared', name: '方格纸', type: 'squared', color: '#FFFFFF', lineColor: '#D9DEE8', spacing: 24),
    WbBackgroundPreset(id: 'dark-dot', name: '深色点阵', type: 'dot', color: '#121417', lineColor: '#2A2F3A', spacing: 20, dark: true),
    WbBackgroundPreset(id: 'dark-grid', name: '深色网格', type: 'grid', color: '#121417', lineColor: '#2A2F3A', spacing: 25, dark: true),
  ];

  /// 按 id 查找内置预设（未知返回 null）。
  static WbBackgroundPreset? presetById(String id) {
    for (final WbBackgroundPreset preset in builtinPresets) {
      if (preset.id == id) {
        return preset;
      }
    }
    return null;
  }

  /// 应用内置预设（客户端解析为完整背景对象后写入，见 [WbBackgroundPreset.toBackgroundJson]）。
  Map<String, dynamic> setPreset(String pageId, String presetId) {
    final WbBackgroundPreset? preset = presetById(presetId);
    if (preset == null) {
      throw WbCoreException('NotFound', 'unknown background preset: $presetId');
    }
    return apply(pageId, preset.toBackgroundJson());
  }

  /// 应用背景：`wb_page_set_background` 的第二个参数即"背景对象本体"，
  /// 接受的三种入参：
  /// 1. 完整背景对象（如 [WbBackgroundPreset.toBackgroundJson] 的结果）：直通；
  /// 2. `{'preset': id}`：客户端解析为完整背景对象；
  /// 3. `{'background': {...}}` 包裹：自动解包。
  ///
  /// 返回 `{pageId, background}`（与 background 域 set 的结果形态一致）。
  Map<String, dynamic> apply(
    String pageId,
    Map<String, dynamic> background,
  ) {
    Map<String, dynamic> resolved = background;
    if (background.length == 1) {
      final Object? wrapped = background['background'];
      final Object? preset = background['preset'];
      if (wrapped is Map) {
        resolved = Map<String, dynamic>.from(wrapped);
      } else if (preset is String) {
        final WbBackgroundPreset? found = presetById(preset);
        if (found == null) {
          throw WbCoreException(
            'NotFound',
            'unknown background preset: $preset',
          );
        }
        resolved = found.toBackgroundJson();
      }
    }
    final WbResponse response = WbResponse.parse(
      ffi.call2(
        ffi.bindings.wbPageSetBackground,
        pageId,
        WbJsonCodec.encode(resolved),
      ),
    );
    // 归一化：page 域返回 `{page: {...}, inverse: ...}`，统一为
    // `{pageId, background}`（与 background 域 set 的结果形态一致）。
    final Map<String, dynamic> result = response.requireResult();
    final Map<String, dynamic> page = WbJsonCodec.unwrap(result, 'page');
    final Object? backgroundValue = page['background'] ?? result['background'];
    return <String, dynamic>{
      'pageId': pageId,
      'background': backgroundValue is Map
          ? Map<String, dynamic>.from(backgroundValue)
          : resolved,
    };
  }

  /// 复位为默认白板底色。
  Map<String, dynamic> clear(String pageId) => setPreset(pageId, 'whiteboard');

  /// 供页面服务复用的底层转发。
  WbPageService get pages => _pageService;
}
