/// 设置页：外观（主题 / 背景 / 无障碍）、快捷键、AI 助手、协作同步与关于
/// （《主题与背景系统设计》§8–§10；《白板软件设计文档》§1.2、§8）。
///
/// 所有 Provider 读取均为**可空查找**：未挂载 Provider 时页面仍可渲染
/// （回退本地主题状态），便于组件测试与独立预览。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_ai/ai_client.dart';
import 'package:whiteboard_core/wb_core.dart' show WbBackgroundService;
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_theme/theme.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

import '../platform/platform_service.dart';
import '../platform/window_service.dart';
import '../services/ffi_service.dart';
import '../services/settings_store.dart';
import '../services/shortcut_service.dart';
import '../services/sync_service.dart';
import '../services/theme_service.dart';
import '../state/ai_state.dart';
import '../state/page_state.dart';
import '../state/theme_state.dart';
import '../widgets/settings/accessibility_settings.dart';
import '../widgets/settings/background_picker.dart';
import '../widgets/settings/hotkey_settings.dart';
import '../widgets/settings/settings_section.dart';
import '../widgets/settings/theme_selector.dart';

/// 设置页。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _modelController =
      TextEditingController(text: 'gpt-4o-mini');
  final TextEditingController _baseUrlController =
      TextEditingController(text: 'http://localhost:8080/v1');
  final TextEditingController _serverController = TextEditingController();

  String _providerKind = 'openai';

  /// 设置存储（可空：未挂载 Provider 时仅内存态，不落盘）。
  WbSettingsStore? _store;

  /// 无 Provider 环境下的本地回退主题状态（组件测试 / 独立预览用）。
  WbThemeState? _fallbackTheme;

  /// 外观偏好草稿：打开页面后所有外观改动先暂存于此，
  /// 点「保存」才统一应用到 [WbThemeState]；返回 / 取消则整体丢弃。
  WbAppearancePrefs? _draft;

  /// 草稿主题 id（保存时切换主题）。
  String? _draftThemeId;

  @override
  void initState() {
    super.initState();
    final WbSettingsStore? store = context.read<WbSettingsStore?>();
    _store = store;
    // 回填已持久化的 AI 配置（从未配置时保留默认值）。
    final WbAiSettings? ai = store?.ai;
    if (ai != null) {
      _providerKind = ai.kind;
      _apiKeyController.text = ai.apiKey;
      if (ai.model.isNotEmpty) {
        _modelController.text = ai.model;
      }
      if (ai.baseUrl.isNotEmpty) {
        _baseUrlController.text = ai.baseUrl;
      }
    }
    // 回填协作服务地址。
    final String syncUrl = store?.syncServerUrl ?? '';
    if (syncUrl.isNotEmpty) {
      _serverController.text = syncUrl;
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _modelController.dispose();
    _baseUrlController.dispose();
    _serverController.dispose();
    _fallbackTheme?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 草稿（外观偏好暂存）
  // ---------------------------------------------------------------------------

  /// 取（或初始化）外观草稿（首次 build 时从主题状态快照）。
  WbAppearancePrefs _ensureDraft(WbThemeState theme) =>
      _draft ??= theme.appearance;

  /// 取（或初始化）草稿主题 id。
  String _ensureDraftThemeId(WbThemeState theme) =>
      _draftThemeId ??= theme.current.id;

  /// 更新草稿并重建（不动全局主题状态）。
  void _updateDraft(WbAppearancePrefs next) {
    setState(() => _draft = next);
  }

  /// 解析草稿状态下的生效主题 id（跟随系统开启时按平台亮度匹配）。
  String? _resolveDraftEffectiveThemeId(
    WbThemeState theme,
    String draftThemeId,
    bool followSystem,
  ) {
    if (!followSystem) {
      return null;
    }
    final Brightness systemBrightness =
        MediaQuery.maybePlatformBrightnessOf(context) ?? Brightness.light;
    final bool systemDark = systemBrightness == Brightness.dark;
    WbThemeData? base;
    for (final WbThemeData item in theme.available) {
      if (item.id == draftThemeId) {
        base = item;
        break;
      }
    }
    base ??= theme.current;
    if (base.dark == systemDark) {
      return base.id;
    }
    for (final WbThemeData item in theme.available) {
      if (item.dark == systemDark) {
        return item.id;
      }
    }
    return base.id;
  }

  /// 取消：丢弃草稿直接返回。
  void _cancel() {
    Navigator.of(context).maybePop();
  }

  /// 保存：切换主题 → 一次性应用草稿外观 → 应用窗口模式 → 关闭。
  void _save(WbThemeState theme, WbAppearancePrefs draft, String draftThemeId) {
    if (draftThemeId != theme.current.id) {
      theme.select(draftThemeId);
    }
    theme.applyAppearance(draft);
    unawaited(
      WbWindowService().applyWindowMode(
        blackboard:
            draft.windowMode == WbAppearancePrefs.windowModeBlackboard,
      ),
    );
    Navigator.of(context).maybePop();
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// 将宿主壳层的系统亮度上报给主题状态（跟随系统开关依赖其值）。
  ///
  /// 亮度变化时经 post-frame 回调上报，避免构建期触发 notifyListeners。
  void _syncPlatformBrightness(WbThemeState theme) {
    final Brightness current =
        MediaQuery.maybePlatformBrightnessOf(context) ?? Brightness.light;
    if (theme.platformBrightness == current) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        theme.updatePlatformBrightness(current);
      }
    });
  }

  /// 按字号缩放 / 减少动效包装 MediaQuery（文档 §8.5 / §9）。
  ///
  /// 使用草稿值预览：改动即时反映在设置页自身，但未保存不影响全局。
  Widget _wrapScaler(
    BuildContext context,
    WbAppearancePrefs draft,
    Widget child,
  ) {
    final MediaQueryData? mq = MediaQuery.maybeOf(context);
    if (mq == null) {
      return child;
    }
    final double scale =
        (mq.textScaler.scale(1.0) * draft.fontScale).clamp(0.5, 3.0).toDouble();
    return MediaQuery(
      key: const ValueKey<String>('settings-scaler'),
      data: mq.copyWith(
        textScaler: TextScaler.linear(scale),
        disableAnimations: mq.disableAnimations || draft.reduceMotion,
      ),
      child: child,
    );
  }

  // ---------------------------------------------------------------------------
  // 主题 / 背景
  // ---------------------------------------------------------------------------

  Future<void> _importTheme(WbThemeState theme) async {
    final WbThemePack? pack = await showWbThemeImportDialog(context);
    if (!mounted || pack == null) {
      return;
    }
    theme.importPack(pack);
    // 导入后管理器已应用第一个主题，同步草稿主题 id 保持选中一致。
    _draftThemeId = theme.current.id;
    _snack('已导入主题包「${pack.name}」，共 ${pack.themes.length} 个主题（已应用第一个）');
  }

  void _exportTheme(WbThemeState theme) {
    unawaited(showWbThemeExportDialog(context, theme.current));
  }

  Future<void> _pickBackgroundColor(WbAppearancePrefs draft) async {
    final Color initial = draft.backgroundCustomColor.isEmpty
        ? const Color(0xFFFFFFFF)
        : WbColorUtils.fromHex(
            draft.backgroundCustomColor,
            fallback: const Color(0xFFFFFFFF),
          );
    final Color? color = await showWbBackgroundColorDialog(
      context,
      initialColor: initial,
    );
    if (!mounted || color == null) {
      return;
    }
    _updateDraft(draft.copyWith(backgroundCustomColor: WbColorUtils.toHex(color)));
    _snack('自定义背景色已选用 ${WbColorUtils.toHex(color)}，可「应用到当前页」');
  }

  Future<void> _pickPatternColor(WbAppearancePrefs draft) async {
    final Color? color = await showWbBackgroundColorDialog(
      context,
      initialColor: WbColorUtils.fromHex(
        draft.backgroundPatternColor,
        fallback: const Color(0xFFD0D5DD),
      ),
      title: '图案颜色',
    );
    if (!mounted || color == null) {
      return;
    }
    _updateDraft(draft.copyWith(backgroundPatternColor: WbColorUtils.toHex(color)));
    _snack('图案颜色已设为 ${WbColorUtils.toHex(color)}');
  }

  /// 将当前背景配置应用到当前页 / 全部页（经 `WbPageState.setBackground`）。
  ///
  /// 使用草稿配置（含未保存改动），与应用即时生效的语义一致。
  void _applyBackground(WbAppearancePrefs draft, {required bool all}) {
    final Map<String, dynamic>? json = WbThemeState.backgroundJsonOf(draft);
    if (json == null) {
      _snack('当前背景配置无效（未知预设 id），请重新选择');
      return;
    }
    final WbPageState? pages = context.read<WbPageState?>();
    if (pages == null || pages.pages.isEmpty) {
      _snack('没有可应用背景的页面（请先打开白板）');
      return;
    }
    if (all) {
      for (final page in pages.pages) {
        pages.setBackground(page.id, json);
      }
      _snack('背景已应用到全部 ${pages.pages.length} 页');
    } else {
      pages.setBackground(pages.currentPageId, json);
      _snack('背景已应用到当前页');
    }
  }

  // ---------------------------------------------------------------------------
  // AI / 协作（沿用骨架逻辑，改为可空查找）
  // ---------------------------------------------------------------------------

  void _applyAi() {
    final WbAiState? ai = context.read<WbAiState?>();
    if (ai == null) {
      _snack('AI 状态未挂载（Provider 缺失），无法应用配置');
      return;
    }
    final WbAiSettings settings = WbAiSettings(
      kind: _providerKind,
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
    );
    final AiProvider provider = settings.build();
    ai.configure(provider);
    // 持久化（启动恢复经 WbSettingsStore.ai → build() 共用同一套回退语义）。
    _store?.ai = settings;
    _snack('AI 提供商已应用：${provider.id}');
  }

  Future<void> _applySync() async {
    final WbSyncService? sync = context.read<WbSyncService?>();
    if (sync == null) {
      _snack('协作服务未挂载（Provider 缺失）');
      return;
    }
    final String url = _serverController.text.trim();
    if (sync.isOnline) {
      await sync.disconnect();
    } else {
      await sync.connect(url);
      if (url.isNotEmpty) {
        // 连接成功即持久化地址，下次启动自动回填。
        _store?.syncServerUrl = url;
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final WbThemeState? providedTheme = context.watch<WbThemeState?>();
    final WbThemeState theme = providedTheme ?? (_fallbackTheme ??= WbThemeState());
    final WbAiState? ai = context.watch<WbAiState?>();
    final WbSyncService? sync = context.watch<WbSyncService?>();
    final WbFfiService? ffi = context.read<WbFfiService?>();
    _syncPlatformBrightness(theme);

    // 外观草稿：所有外观控件改草稿、预览即改即显，点「保存」才统一应用。
    final WbAppearancePrefs draft = _ensureDraft(theme);
    final String draftThemeId = _ensureDraftThemeId(theme);

    return ListenableBuilder(
      listenable: theme,
      builder: (BuildContext context, Widget? child) {
        final WbThemeColors colors = context.wbColors;
        final TextTheme text = Theme.of(context).textTheme;
        final bool highContrast = draft.highContrast;

        return _wrapScaler(
          context,
          draft,
          Scaffold(
            appBar: AppBar(
              title: const Text('设置'),
              backgroundColor: colors.surface,
              actions: <Widget>[
                TextButton(
                  key: const ValueKey<String>('settings-cancel'),
                  onPressed: _cancel,
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey<String>('settings-save'),
                  onPressed: () => _save(theme, draft, draftThemeId),
                  child: const Text('保存'),
                ),
                const SizedBox(width: 16),
              ],
            ),
            body: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: <Widget>[
                    // ---- 外观：主题 ----
                    SettingsSection(
                      title: '主题',
                      icon: LinearIcons.palette,
                      subtitle: '内置 9 套主题；点右上角「保存」后统一生效（文档 §8.5）',
                      highContrast: highContrast,
                      children: <Widget>[
                        ThemeSelector(
                          themes: theme.available,
                          selectedId: draftThemeId,
                          onSelect: (String id) => setState(() {
                            _draftThemeId = id;
                            // 背景跟随主题开启且未自定义色时，草稿背景同步
                            // 为新主题默认（与运行时联动规则一致）。
                            if (draft.backgroundFollowTheme &&
                                draft.backgroundCustomColor.isEmpty) {
                              _draft = draft.copyWith(
                                backgroundPresetId:
                                    WbThemeState.defaultBackgroundFor(id),
                              );
                            }
                          }),
                          effectiveThemeId: _resolveDraftEffectiveThemeId(
                            theme,
                            draftThemeId,
                            draft.followSystem,
                          ),
                          followSystem: draft.followSystem,
                          onFollowSystemChanged: (bool value) =>
                              _updateDraft(
                            draft.copyWith(followSystem: value),
                          ),
                          iconStyleId: draft.iconStyle,
                          onIconStyleChanged: (String id) => _updateDraft(
                            draft.copyWith(iconStyle: WbIconStyle.fromId(id).id),
                          ),
                          onImport: () => unawaited(_importTheme(theme)),
                          onExport: () => _exportTheme(theme),
                          reduceMotion: draft.reduceMotion,
                          highContrast: highContrast,
                        ),
                      ],
                    ),
                    // ---- 外观：背景 ----
                    SettingsSection(
                      title: '背景',
                      icon: LinearIcons.grid,
                      subtitle: '11 个内置预设 + 自定义色；选择后应用到页面（文档 §8.2）',
                      highContrast: highContrast,
                      children: <Widget>[
                        BackgroundPicker(
                          presets: WbBackgroundService.builtinPresets,
                          selectedPresetId: draft.backgroundPresetId,
                          customColor: draft.backgroundCustomColor,
                          onPresetSelected: (String id) => _updateDraft(
                            draft.copyWith(
                              backgroundPresetId: id,
                              backgroundCustomColor: '',
                            ),
                          ),
                          onPickCustomColor: () =>
                              unawaited(_pickBackgroundColor(draft)),
                          followTheme: draft.backgroundFollowTheme,
                          onFollowThemeChanged: (bool value) => _updateDraft(
                            draft.copyWith(
                              backgroundFollowTheme: value,
                              // 开启联动时同步为草稿主题的默认背景，
                              // 与保存后 applyAppearance 的联动结果一致。
                              backgroundPresetId: value
                                  ? WbThemeState.defaultBackgroundFor(
                                      draftThemeId,
                                    )
                                  : draft.backgroundPresetId,
                              backgroundCustomColor:
                                  value ? '' : draft.backgroundCustomColor,
                            ),
                          ),
                          spacing: draft.backgroundSpacing,
                          onSpacingChanged: (int value) => _updateDraft(
                            draft.copyWith(
                              backgroundSpacing: value.clamp(0, 120),
                            ),
                          ),
                          patternColor: draft.backgroundPatternColor,
                          onPickPatternColor: () =>
                              unawaited(_pickPatternColor(draft)),
                          opacity: draft.backgroundOpacity,
                          onOpacityChanged: (double value) => _updateDraft(
                            draft.copyWith(
                              backgroundOpacity: value.clamp(0.0, 1.0),
                            ),
                          ),
                          onApplyToCurrentPage: () =>
                              _applyBackground(draft, all: false),
                          onApplyToAllPages: () =>
                              _applyBackground(draft, all: true),
                          reduceMotion: draft.reduceMotion,
                          highContrast: highContrast,
                        ),
                      ],
                    ),
                    // ---- 外观：无障碍 ----
                    SettingsSection(
                      title: '无障碍',
                      icon: LinearIcons.visible,
                      subtitle: '减少动效 / 减少透明度 / 高对比度 / 字号缩放（文档 §9）',
                      highContrast: highContrast,
                      children: <Widget>[
                        AccessibilitySettings(
                          reduceMotion: draft.reduceMotion,
                          onReduceMotionChanged: (bool value) =>
                              _updateDraft(
                            draft.copyWith(reduceMotion: value),
                          ),
                          reduceTransparency: draft.reduceTransparency,
                          onReduceTransparencyChanged: (bool value) =>
                              _updateDraft(
                            draft.copyWith(reduceTransparency: value),
                          ),
                          highContrast: draft.highContrast,
                          onHighContrastChanged: (bool value) =>
                              _updateDraft(
                            draft.copyWith(highContrast: value),
                          ),
                          fontScale: draft.fontScale,
                          onFontScaleChanged: (double value) => _updateDraft(
                            draft.copyWith(
                              fontScale: value.clamp(
                                WbAppearancePrefs.minFontScale,
                                WbAppearancePrefs.maxFontScale,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    // ---- 界面与窗口 ----
                    SettingsSection(
                      title: '界面与窗口',
                      icon: LinearIcons.fullscreen,
                      subtitle: '工具栏风格二选一与窗口模式；保存后立即生效',
                      highContrast: highContrast,
                      children: <Widget>[
                        SettingsTile(
                          leading: Icon(
                            LinearIcons.board,
                            size: 18,
                            color: colors.icon,
                          ),
                          title: '工具栏风格（二选一）',
                          subtitle: draft.toolbarStyle ==
                                  WbAppearancePrefs.toolbarStyleTop
                              ? '顶部工具面板：显示在画布左上角'
                              : '齿轮圆盘：显示在画布右下角（可拖动）',
                          trailing: SegmentedButton<String>(
                            key: const ValueKey<String>('settings-toolbar-style'),
                            segments: const <ButtonSegment<String>>[
                              ButtonSegment<String>(
                                value: WbAppearancePrefs.toolbarStyleRadial,
                                label: Text('圆盘'),
                              ),
                              ButtonSegment<String>(
                                value: WbAppearancePrefs.toolbarStyleTop,
                                label: Text('顶部'),
                              ),
                            ],
                            selected: <String>{draft.toolbarStyle},
                            onSelectionChanged: (Set<String> selection) =>
                                _updateDraft(
                              draft.copyWith(toolbarStyle: selection.first),
                            ),
                          ),
                        ),
                        SettingsTile(
                          leading: Icon(
                            LinearIcons.fullscreen,
                            size: 18,
                            color: colors.icon,
                          ),
                          title: '窗口模式',
                          subtitle: draft.windowMode ==
                                  WbAppearancePrefs.windowModeBlackboard
                              ? '黑板模式：隐藏窗口标题栏直接全屏'
                              : '窗口模式：常规窗口，保留标题栏与边框',
                          trailing: SegmentedButton<String>(
                            key: const ValueKey<String>('settings-window-mode'),
                            segments: const <ButtonSegment<String>>[
                              ButtonSegment<String>(
                                value: WbAppearancePrefs.windowModeWindow,
                                label: Text('窗口'),
                              ),
                              ButtonSegment<String>(
                                value: WbAppearancePrefs.windowModeBlackboard,
                                label: Text('黑板'),
                              ),
                            ],
                            selected: <String>{draft.windowMode},
                            onSelectionChanged: (Set<String> selection) =>
                                _updateDraft(
                              draft.copyWith(windowMode: selection.first),
                            ),
                          ),
                        ),
                      ],
                    ),
                    // ---- 快捷键 ----
                    SettingsSection(
                      title: '快捷键',
                      icon: LinearIcons.table,
                      subtitle: '文档 §8 总表（只读）；键位冲突检测基于实际注册表',
                      highContrast: highContrast,
                      children: <Widget>[
                        HotkeySettings(shortcuts: WbShortcutService.defaults),
                      ],
                    ),
                    // ---- AI 助手 ----
                    SettingsSection(
                      title: 'AI 助手',
                      icon: LinearIcons.ai,
                      highContrast: highContrast,
                      children: <Widget>[
                        SegmentedButton<String>(
                          segments: const <ButtonSegment<String>>[
                            ButtonSegment<String>(
                              value: 'openai',
                              label: Text('OpenAI'),
                            ),
                            ButtonSegment<String>(
                              value: 'anthropic',
                              label: Text('Anthropic'),
                            ),
                            ButtonSegment<String>(
                              value: 'custom',
                              label: Text('自定义网关'),
                            ),
                          ],
                          selected: <String>{_providerKind},
                          onSelectionChanged: (Set<String> selection) {
                            setState(() => _providerKind = selection.first);
                          },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _apiKeyController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'API Key',
                            hintText: '明文保存在本机（settings.json，请妥善保管）',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _modelController,
                          decoration: const InputDecoration(
                            labelText: '模型',
                            hintText: '如 gpt-4o-mini / claude-3-5-sonnet-latest',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        if (_providerKind == 'custom') ...<Widget>[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _baseUrlController,
                            decoration: const InputDecoration(
                              labelText: 'Base URL（OpenAI 兼容）',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          children: <Widget>[
                            FilledButton.icon(
                              onPressed: _applyAi,
                              icon: const Icon(LinearIcons.check),
                              label: const Text('应用配置'),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                ai == null
                                    ? 'AI 状态未挂载（Provider 缺失）'
                                    : (ai.isConfigured
                                        ? '当前提供商：${ai.aiService.provider?.id ?? '-'}'
                                        : '尚未配置（AI 面板将提示配置引导）'),
                                style: text.bodySmall
                                    ?.copyWith(color: colors.icon),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    // ---- 协作同步 ----
                    SettingsSection(
                      title: '协作同步',
                      icon: LinearIcons.cloud,
                      highContrast: highContrast,
                      children: <Widget>[
                        TextField(
                          controller: _serverController,
                          decoration: const InputDecoration(
                            labelText: '协作服务地址',
                            hintText: 'wss://sync.example.com/board',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: <Widget>[
                            FilledButton.icon(
                              onPressed: () => unawaited(_applySync()),
                              icon: Icon(
                                sync?.isOnline == true
                                    ? LinearIcons.offline
                                    : LinearIcons.cloud,
                              ),
                              label: Text(
                                sync?.isOnline == true ? '断开连接' : '连接',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '状态：${sync?.status.label ?? '未挂载'}'
                              '（真实链路 Wave 3 接入）',
                              style: text.bodySmall
                                  ?.copyWith(color: colors.icon),
                            ),
                          ],
                        ),
                      ],
                    ),
                    // ---- 关于 ----
                    SettingsSection(
                      title: '关于',
                      icon: LinearIcons.info,
                      highContrast: highContrast,
                      children: <Widget>[
                        const ListTile(
                          dense: true,
                          leading: Icon(LinearIcons.info),
                          title: Text('Whiteboard 桌面版'),
                          subtitle: Text('版本 1.0.0（Wave 3 深度实现）'),
                        ),
                        ListTile(
                          dense: true,
                          leading: const Icon(LinearIcons.grid),
                          title: Text('平台：${WbPlatformService.platformName}'),
                          subtitle:
                              const Text('Flutter + C++ 核心引擎（wb_core）'),
                        ),
                        ListTile(
                          dense: true,
                          leading: Icon(
                            ffi?.isAvailable == true
                                ? LinearIcons.cloud
                                : LinearIcons.offline,
                          ),
                          title: Text(
                            ffi?.isAvailable == true
                                ? '引擎已加载'
                                : '引擎未加载（演示模式）',
                          ),
                          subtitle: Text(
                            ffi?.isAvailable == true
                                ? (ffi?.loadedFrom ?? '')
                                : '${ffi?.error ?? '未初始化'}',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
