/// 设置页深度测试：草稿模式保存 / 主题切换 / 跟随系统 / 背景选择 / 无障碍 /
/// 快捷键 / 导入导出 / 无 Provider 独立渲染（Wave 3.8）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:whiteboard_core/wb_core.dart' show WbBackgroundService;
import 'package:whiteboard_desktop/pages/settings_page.dart';
import 'package:whiteboard_desktop/services/ffi_service.dart';
import 'package:whiteboard_desktop/services/shortcut_service.dart';
import 'package:whiteboard_desktop/services/theme_service.dart';
import 'package:whiteboard_desktop/state/board_state.dart';
import 'package:whiteboard_desktop/state/page_state.dart';
import 'package:whiteboard_desktop/state/theme_state.dart';
import 'package:whiteboard_desktop/widgets/settings/hotkey_settings.dart';
import 'package:whiteboard_desktop/widgets/settings/theme_selector.dart';

/// 构造演示模式 FFI 服务（候选路径必然失败，保证测试确定性）。
WbFfiService _demoFfi() {
  return WbFfiService(candidatePaths: const <String>['__wb_missing__.dll'])
    ..initialize();
}

/// 放大的测试视口：设置页为长列表，避免分区被视口裁剪而不构建。
void _useLargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1500, 8000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 排空 SnackBar（等待 4s 显示 + 退场动画），避免 pending timer。
Future<void> _drainSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// 内置主题 id（9 个，顺序与 WbBuiltinThemes.all 一致）。
const List<String> _builtinThemeIds = <String>[
  'clean-professional',
  'dark-night',
  'blackboard',
  'greenboard',
  'minimal',
  'hand-drawn',
  'cyber',
  'kids',
  'enterprise',
];

const List<String> _presetIds = <String>[
  'whiteboard',
  'light-gray',
  'dot',
  'grid',
  'blackboard',
  'greenboard',
  'cream',
  'lined',
  'squared',
  'dark-dot',
  'dark-grid',
];

/// 有效主题包 JSON（1 个自定义主题「海洋」）。
const String _packJson = r'''
{
  "id": "test.ocean-pack",
  "name": "海洋主题包",
  "themes": [
    {
      "id": "ocean",
      "name": "海洋",
      "dark": false,
      "colors": {
        "bg.canvas": "#E3F2FD",
        "bg.surface": "#FFFFFF",
        "bg.elevated": "#FFFFFF",
        "primary": "#0288D1",
        "toolbar.icon": "#37474F",
        "card.hover": "#F2F4F7",
        "card.border": "#E4E7EC"
      }
    }
  ]
}
''';

/// 完整 Provider 环境（主题 + 可选页面状态）。
Widget _app({required WbThemeState theme, WbPageState? pages}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<WbThemeState>.value(value: theme),
      if (pages != null)
        ChangeNotifierProvider<WbPageState>.value(value: pages),
    ],
    child: ListenableBuilder(
      listenable: theme,
      builder: (BuildContext context, Widget? _) => MaterialApp(
        theme: theme.flutterThemeData,
        home: const SettingsPage(),
      ),
    ),
  );
}

/// 挂载设置页并等待首帧完成。
Future<void> _pumpSettings(
  WidgetTester tester, {
  required WbThemeState theme,
  WbPageState? pages,
}) async {
  await tester.pumpWidget(_app(theme: theme, pages: pages));
  await tester.pumpAndSettle();
}

/// 构造 2 页的页面状态 fixture（演示模式）。
WbPageState _twoPageFixture({required WbBoardState board, required WbFfiService ffi}) {
  final WbPageState pages = WbPageState(ffi: ffi)..attach(board.board!);
  pages.addPage();
  return pages;
}

BoxDecoration _sectionCardDecoration(WidgetTester tester, String title) {
  final Container card = tester
      .widget<Container>(find.byKey(ValueKey<String>('settings-section-card-$title')));
  return card.decoration! as BoxDecoration;
}

void main() {
  group('外观偏好与背景 JSON（单元）', () {
    test('WbAppearancePrefs JSON 往返且越界值被夹取', () {
      const WbAppearancePrefs prefs = WbAppearancePrefs(
        followSystem: true,
        iconStyle: 'pixel',
        fontScale: 1.25,
        reduceMotion: true,
        highContrast: true,
        backgroundFollowTheme: false,
        backgroundPresetId: 'grid',
        backgroundSpacing: 32,
        backgroundOpacity: 0.8,
        toolbarStyle: WbAppearancePrefs.toolbarStyleTop,
        windowMode: WbAppearancePrefs.windowModeBlackboard,
        shortcutOverrides: <String, List<String>>{
          'cmd.palette': <String>['Ctrl', 'Shift', 'P'],
        },
      );
      final WbAppearancePrefs restored =
          WbAppearancePrefs.fromJson(prefs.toJson());
      expect(restored.followSystem, isTrue);
      expect(restored.iconStyle, 'pixel');
      expect(restored.fontScale, 1.25);
      expect(restored.reduceMotion, isTrue);
      expect(restored.highContrast, isTrue);
      expect(restored.backgroundFollowTheme, isFalse);
      expect(restored.backgroundPresetId, 'grid');
      expect(restored.backgroundSpacing, 32);
      expect(restored.backgroundOpacity, 0.8);
      expect(restored.toolbarStyle, WbAppearancePrefs.toolbarStyleTop);
      expect(restored.windowMode, WbAppearancePrefs.windowModeBlackboard);
      expect(
        restored.shortcutOverrides['cmd.palette'],
        <String>['Ctrl', 'Shift', 'P'],
      );
      expect(restored, prefs);

      final WbAppearancePrefs clamped = WbAppearancePrefs.fromJson(
        <String, dynamic>{'fontScale': 9.0, 'backgroundOpacity': -3.0},
      );
      expect(clamped.fontScale, WbAppearancePrefs.maxFontScale);
      expect(clamped.backgroundOpacity, 0.0);
    });

    test('主题默认背景映射覆盖内置主题', () {
      expect(WbThemeState.defaultBackgroundFor('dark-night'), 'dark-dot');
      expect(WbThemeState.defaultBackgroundFor('blackboard'), 'blackboard');
      expect(WbThemeState.defaultBackgroundFor('greenboard'), 'greenboard');
      expect(WbThemeState.defaultBackgroundFor('minimal'), 'whiteboard');
      expect(WbThemeState.defaultBackgroundFor('hand-drawn'), 'cream');
      expect(WbThemeState.defaultBackgroundFor('cyber'), 'dark-grid');
      expect(WbThemeState.defaultBackgroundFor('unknown'), 'light-gray');
    });

    test('backgroundJson：预设 / 自定义色 / 参数覆盖形态', () {
      final WbThemeState state = WbThemeState();
      addTearDown(state.dispose);

      // 默认：浅灰白板预设，与 WbBackgroundService 契约一致。
      Map<String, dynamic> json = state.backgroundJson!;
      expect(json['id'], 'light-gray');
      expect(json['pattern'], 'solid');
      expect(json['preset'], 'light-gray');

      // 图案预设 + 参数覆盖。
      state.selectBackgroundPreset('dot');
      state.setBackgroundSpacing(40);
      state.setBackgroundPatternColor(const Color(0xFF123456));
      state.setBackgroundOpacity(0.5);
      json = state.backgroundJson!;
      expect(json['pattern'], 'dot');
      expect(json['spacing'], 40);
      expect(json['patternColor'], '#123456');
      expect(json['opacity'], 0.5);

      // 自定义色优先于预设。
      state.selectBackgroundColor(const Color(0xFFAB12CD));
      json = state.backgroundJson!;
      expect(json['id'], 'custom');
      expect(json['custom'], isTrue);
      expect(json['baseColor'], '#AB12CD');
      expect(json['pattern'], 'solid');

      // 预设选择清除自定义色。
      state.selectBackgroundPreset('grid');
      expect(state.backgroundCustomColor, isEmpty);
      expect(state.backgroundJson!['id'], 'grid');
    });

    test('快捷键冲突检测：同键位多动作 / 默认表无冲突', () {
      final List<WbShortcut> conflicted = <WbShortcut>[
        const WbShortcut(
          id: 'a.act',
          label: '动作 A',
          activator: SingleActivator(LogicalKeyboardKey.keyK, control: true),
          scope: WbShortcutScope.global,
        ),
        const WbShortcut(
          id: 'b.act',
          label: '动作 B',
          activator: SingleActivator(LogicalKeyboardKey.keyK, control: true),
          scope: WbShortcutScope.global,
        ),
        const WbShortcut(
          id: 'c.act',
          label: '动作 C',
          activator: SingleActivator(LogicalKeyboardKey.keyL, control: true),
        ),
      ];
      final List<WbShortcutConflict> conflicts =
          HotkeySettings.conflicts(conflicted);
      expect(conflicts.length, 1);
      expect(conflicts.single.keys, 'Ctrl+K');
      expect(conflicts.single.ids, <String>['a.act', 'b.act']);

      expect(HotkeySettings.conflicts(WbShortcutService.defaults), isEmpty);
      expect(WbShortcutService.defaults.length, 12);
    });
  });

  group('设置页（Provider 环境）', () {
    testWidgets('七个分区 / 9 主题卡片 / 11 背景预设全渲染', (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      for (final String title in <String>[
        '主题',
        '背景',
        '无障碍',
        '界面与窗口',
        '快捷键',
        'AI 助手',
        '协作同步',
        '关于',
      ]) {
        expect(
          find.byKey(ValueKey<String>('settings-section-card-$title')),
          findsOneWidget,
          reason: '缺少分区：$title',
        );
      }
      for (final String id in _builtinThemeIds) {
        expect(find.byKey(ValueKey<String>('theme-card-$id')), findsOneWidget);
      }
      expect(find.byType(WbThemePreview), findsNWidgets(9));
      expect(WbBackgroundService.builtinPresets.length, 11);
      for (final String id in _presetIds) {
        expect(
          find.byKey(ValueKey<String>('background-preset-$id')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey<String>('background-custom-color')),
        findsOneWidget,
      );
      // 快捷键文档总表分组。
      expect(find.byKey(const ValueKey<String>('hotkey-keys-cmd.palette')),
          findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('hotkey-conflict-clear')),
        findsOneWidget,
      );
      // 界面与窗口控件 + 顶栏保存 / 取消。
      expect(find.byKey(const ValueKey<String>('settings-toolbar-style')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('settings-window-mode')),
          findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('settings-save')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('settings-cancel')),
        findsOneWidget,
      );
    });

    testWidgets('草稿模式：主题卡片改动暂存，保存后切换并持久化',
        (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      expect(find.byKey(const ValueKey<String>('theme-card-check-clean-professional')),
          findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('theme-card-dark-night')));
      await tester.pumpAndSettle();

      // 草稿态：勾选即时切换，但全局主题不变。
      expect(find.byKey(const ValueKey<String>('theme-card-check-dark-night')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('theme-card-check-clean-professional')),
          findsNothing);
      expect(theme.current.id, isNot('dark-night'));

      // 保存后应用并持久化；背景跟随主题同步为暗夜默认背景。
      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.current.id, 'dark-night');
      expect(theme.service.persistedThemeId, 'dark-night');
      expect(theme.backgroundPresetId, 'dark-dot');
    });

    testWidgets('跟随系统：系统暗色时生效主题为 dark-night 并打标',
        (WidgetTester tester) async {
      _useLargeViewport(tester);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      expect(theme.platformBrightness, Brightness.dark);

      await tester.tap(find.byKey(const ValueKey<String>('theme-follow-system')));
      await tester.pumpAndSettle();

      // 草稿态即按草稿解析生效主题并打标；未保存不写入全局。
      expect(
        find.byKey(const ValueKey<String>('theme-card-effective-dark-night')),
        findsOneWidget,
      );
      expect(theme.followSystem, isFalse);

      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.followSystem, isTrue);
      expect(theme.effectiveTheme.id, 'dark-night');
    });

    testWidgets('背景跟随：切换主题联动；关闭后不再联动', (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      expect(theme.backgroundFollowTheme, isTrue);
      await tester.tap(find.byKey(const ValueKey<String>('theme-card-blackboard')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.current.id, 'blackboard');
      expect(theme.backgroundPresetId, 'blackboard', reason: '保存后随主题联动');

      // 关闭跟随（草稿 → 保存）。
      await tester.tap(
        find.byKey(const ValueKey<String>('background-follow-theme')),
      );
      await tester.pumpAndSettle();
      expect(theme.backgroundFollowTheme, isTrue, reason: '草稿未保存不改全局');
      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.backgroundFollowTheme, isFalse);

      await tester.tap(find.byKey(const ValueKey<String>('background-preset-grid')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.backgroundPresetId, 'grid');

      await tester.tap(find.byKey(const ValueKey<String>('theme-card-kids')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.current.id, 'kids');
      expect(theme.backgroundPresetId, 'grid', reason: '关闭跟随主题后不应联动');
    });

    testWidgets('背景应用：当前页 / 全部页写入页面背景', (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbFfiService ffi = _demoFfi();
      final WbBoardState board = WbBoardState(ffi: ffi)..open('demo-settings');
      final WbPageState pages = _twoPageFixture(board: board, ffi: ffi);
      addTearDown(() {
        pages.dispose();
        board.dispose();
      });
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);

      await _pumpSettings(tester, theme: theme, pages: pages);
      expect(pages.pages.length, 2);

      await tester.tap(find.byKey(const ValueKey<String>('background-preset-dot')));
      await tester.pumpAndSettle();
      // 草稿态：预设勾选生效；「应用到页面」直接使用草稿配置（无需保存）。
      expect(find.byKey(const ValueKey<String>('background-check-dot')), findsOneWidget);
      expect(theme.backgroundPresetId, isNot('dot'));

      await tester.tap(
        find.byKey(const ValueKey<String>('background-apply-current')),
      );
      await tester.pump();
      expect(pages.pages[1].background['pattern'], 'dot', reason: '当前页为第 2 页');
      expect(pages.pages.first.background['pattern'], isNull);
      await _drainSnack(tester);

      await tester.tap(
        find.byKey(const ValueKey<String>('background-apply-all')),
      );
      await tester.pump();
      expect(pages.pages.first.background['pattern'], 'dot');
      expect(pages.pages[1].background['preset'], 'dot');
      await _drainSnack(tester);
    });

    testWidgets('自定义背景色：取色器选色后确定并生效',
        (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      await tester.tap(
        find.byKey(const ValueKey<String>('background-custom-color')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('bg-color-dialog')), findsOneWidget);

      final MiuixColorPalette picker = tester.widget<MiuixColorPalette>(
        find.byKey(const ValueKey<String>('bg-color-picker')),
      );
      picker.onColorChanged(const Color(0xFF123456));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey<String>('bg-color-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('background-custom-check')),
          findsOneWidget);
      expect(theme.backgroundCustomColor, isEmpty, reason: '草稿未保存不写全局');

      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.backgroundCustomColor, '#123456');
      expect(theme.backgroundJson!['id'], 'custom');
      await _drainSnack(tester);
    });

    testWidgets('图案参数：间距 / 透明度滑杆与图案色选择写回状态',
        (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      await tester.tap(find.byKey(const ValueKey<String>('background-preset-dot')));
      await tester.pumpAndSettle();

      final MiuixSliderPreference spacing = tester.widget<MiuixSliderPreference>(
        find.byKey(const ValueKey<String>('background-spacing')),
      );
      spacing.onValueChange(40.0);
      await tester.pump();
      expect(find.text('覆盖值：40 px'), findsOneWidget);
      expect(theme.backgroundSpacing, 0, reason: '草稿未保存不写全局');

      final MiuixSliderPreference opacity = tester.widget<MiuixSliderPreference>(
        find.byKey(const ValueKey<String>('background-opacity')),
      );
      opacity.onValueChange(0.6);
      await tester.pump();
      expect(find.text('60%'), findsWidgets);

      await tester.tap(
        find.byKey(const ValueKey<String>('background-pattern-color')),
      );
      await tester.pumpAndSettle();
      final MiuixColorPalette patternPicker = tester.widget<MiuixColorPalette>(
        find.byKey(const ValueKey<String>('bg-color-picker')),
      );
      patternPicker.onColorChanged(const Color(0xFFE8F0FE));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('bg-color-confirm')));
      await tester.pumpAndSettle();
      await _drainSnack(tester);

      // 保存后统一写入全局。
      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.backgroundSpacing, 40);
      expect(theme.backgroundOpacity, closeTo(0.6, 0.0001));
      expect(theme.backgroundPatternColor, '#E8F0FE');

      final Map<String, dynamic> json = theme.backgroundJson!;
      expect(json['spacing'], 40);
      expect(json['opacity'], 0.6);
      expect(json['patternColor'], '#E8F0FE');
    });

    testWidgets('减少动效：状态 + MediaQuery + 卡片动画时长归零',
        (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      AnimatedContainer card() => tester.widget<AnimatedContainer>(
            find.byKey(const ValueKey<String>('theme-card-dark-night')),
          );
      expect(card().duration, isNot(Duration.zero));

      await tester.tap(find.byKey(const ValueKey<String>('a11y-reduce-motion')));
      await tester.pumpAndSettle();

      // 草稿态即时预览：卡片动画与 MediaQuery 同步降级。
      expect(card().duration, Duration.zero);
      final MediaQuery scaler = tester.widget<MediaQuery>(
        find.byKey(const ValueKey<String>('settings-scaler')),
      );
      expect(scaler.data.disableAnimations, isTrue);
      expect(theme.reduceMotion, isFalse, reason: '草稿未保存不写全局');

      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.reduceMotion, isTrue);
      expect(theme.motion(const Duration(milliseconds: 200)), Duration.zero);

      // 关闭后恢复。
      await tester.tap(find.byKey(const ValueKey<String>('a11y-reduce-motion')));
      await tester.pumpAndSettle();
      expect(card().duration, isNot(Duration.zero));
      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.reduceMotion, isFalse);
    });

    testWidgets('字号缩放：滑杆生效 + 重置', (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      final MiuixSliderPreference fontScale = tester.widget<MiuixSliderPreference>(
        find.byKey(const ValueKey<String>('a11y-font-scale')),
      );
      fontScale.onValueChange(1.2);
      await tester.pumpAndSettle();

      // 草稿态即时预览缩放。滑杆数值和说明行都会显示百分比。
      expect(find.text('120%'), findsWidgets);
      final MediaQuery scaler = tester.widget<MediaQuery>(
        find.byKey(const ValueKey<String>('settings-scaler')),
      );
      expect(scaler.data.textScaler.scale(10), closeTo(12, 0.01));
      expect(theme.fontScale, closeTo(1.0, 0.0001), reason: '草稿未保存不写全局');

      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.fontScale, closeTo(1.2, 0.0001));

      await tester.tap(
        find.byKey(const ValueKey<String>('a11y-font-scale-reset')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.fontScale, 1.0);
      expect(find.text('100%'), findsWidgets);
    });

    testWidgets('高对比度：无障碍开关加粗分区描边', (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      Border borderOf(String title) =>
          _sectionCardDecoration(tester, title).border! as Border;
      expect(borderOf('主题').top.width, 1);

      await tester.tap(find.byKey(const ValueKey<String>('a11y-high-contrast')));
      await tester.pumpAndSettle();

      // 草稿态即时预览描边加强。
      expect(borderOf('主题').top.width, 2);
      expect(borderOf('无障碍').top.width, 2);
      expect(theme.highContrast, isFalse, reason: '草稿未保存不写全局');

      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.highContrast, isTrue);
    });

    testWidgets('导入主题包：无效 JSON 报错、有效导入注册并应用',
        (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      await tester.tap(find.byKey(const ValueKey<String>('theme-import')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('theme-import-dialog')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey<String>('theme-import-field')),
        'not-a-json',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('theme-import-confirm')),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('theme-import-error')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey<String>('theme-import-field')),
        _packJson,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('theme-import-preview')),
          findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('theme-import-confirm')),
      );
      await tester.pumpAndSettle();

      expect(theme.available.length, 10);
      expect(theme.current.id, 'ocean');
      expect(find.byKey(const ValueKey<String>('theme-card-ocean')), findsOneWidget);
      await _drainSnack(tester);
    });

    testWidgets('导出对话框：展示当前主题 JSON 并可关闭', (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      await tester.tap(find.byKey(const ValueKey<String>('theme-export')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('theme-export-dialog')), findsOneWidget);

      final SelectableText json = tester.widget<SelectableText>(
        find.byKey(const ValueKey<String>('theme-export-json')),
      );
      expect(json.data, contains('clean-professional'));

      await tester.tap(find.byKey(const ValueKey<String>('theme-export-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('theme-export-dialog')), findsNothing);
    });

    testWidgets('保存 / 取消：关闭设置页并正确应用或丢弃草稿',
        (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<WbThemeState>.value(
          value: theme,
          child: ListenableBuilder(
            listenable: theme,
            builder: (BuildContext context, Widget? _) => MaterialApp(
              theme: theme.flutterThemeData,
              home: Builder(
                builder: (BuildContext context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      key: const ValueKey<String>('open-settings'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) =>
                              const SettingsPage(),
                        ),
                      ),
                      child: const Text('打开设置'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 取消：页面关闭且草稿丢弃。
      await tester.tap(find.byKey(const ValueKey<String>('open-settings')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('theme-card-dark-night')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('settings-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('settings-section-card-主题')),
          findsNothing);
      expect(theme.current.id, isNot('dark-night'));

      // 保存：页面关闭且草稿应用（背景随主题联动）。
      await tester.tap(find.byKey(const ValueKey<String>('open-settings')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('theme-card-dark-night')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('settings-section-card-主题')),
          findsNothing);
      expect(theme.current.id, 'dark-night');
      expect(theme.backgroundPresetId, 'dark-dot');
    });

    testWidgets('界面与窗口：工具栏风格 / 窗口模式草稿 → 保存生效',
        (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState theme = WbThemeState();
      addTearDown(theme.dispose);
      await _pumpSettings(tester, theme: theme);

      Finder segment(String key, String label) => find.descendant(
            of: find.byKey(ValueKey<String>(key)),
            matching: find.text(label),
          );

      expect(
        theme.appearance.toolbarStyle,
        WbAppearancePrefs.toolbarStyleRadial,
      );

      await tester.tap(segment('settings-toolbar-style', '顶部'));
      await tester.pumpAndSettle();
      expect(
        theme.appearance.toolbarStyle,
        WbAppearancePrefs.toolbarStyleRadial,
        reason: '草稿未保存不写全局',
      );

      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(theme.appearance.toolbarStyle, WbAppearancePrefs.toolbarStyleTop);

      await tester.tap(segment('settings-window-mode', '黑板'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('settings-save')));
      await tester.pumpAndSettle();
      expect(
        theme.appearance.windowMode,
        WbAppearancePrefs.windowModeBlackboard,
      );
      expect(
        theme.service.persistedAppearance.toolbarStyle,
        WbAppearancePrefs.toolbarStyleTop,
      );
      expect(
        theme.service.persistedAppearance.windowMode,
        WbAppearancePrefs.windowModeBlackboard,
      );
    });
  });

  group('无 Provider / 独立组件', () {
    testWidgets('无 Provider 独立渲染设置页且可交互', (WidgetTester tester) async {
      _useLargeViewport(tester);
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('settings-section-card-主题')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey<String>('theme-card-cyber')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('theme-card-check-cyber')),
          findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('a11y-reduce-motion')));
      await tester.pumpAndSettle();
      final MediaQuery scaler = tester.widget<MediaQuery>(
        find.byKey(const ValueKey<String>('settings-scaler')),
      );
      expect(scaler.data.disableAnimations, isTrue);

      // 无 WbPageState 时应用背景：提示而非崩溃。
      await tester.tap(
        find.byKey(const ValueKey<String>('background-apply-current')),
      );
      await tester.pump();
      expect(find.text('没有可应用背景的页面（请先打开白板）'), findsOneWidget);
      await _drainSnack(tester);
    });

    testWidgets('ThemeSelector 独立组件：回调上抛 + 禁用态', (WidgetTester tester) async {
      _useLargeViewport(tester);
      final WbThemeState source = WbThemeState();
      addTearDown(source.dispose);

      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ThemeSelector(
                themes: source.available,
                selectedId: 'clean-professional',
                onSelect: (String id) => picked = id,
                onImport: null,
                onExport: null,
              ),
            ),
          ),
        ),
      );

      final MiuixArrowPreference importRow = tester.widget<MiuixArrowPreference>(
        find.byKey(const ValueKey<String>('theme-import')),
      );
      expect(importRow.enabled, isFalse, reason: 'null 回调时导入行禁用');
      expect(importRow.onClick, isNull, reason: 'null 回调时导入行禁用');

      await tester.tap(find.byKey(const ValueKey<String>('theme-card-kids')));
      await tester.pump();
      expect(picked, 'kids');
    });

    testWidgets('HotkeySettings 独立组件：冲突横幅与默认空态',
        (WidgetTester tester) async {
      _useLargeViewport(tester);
      final List<WbShortcut> conflicted = <WbShortcut>[
        const WbShortcut(
          id: 'a.act',
          label: '动作 A',
          activator: SingleActivator(LogicalKeyboardKey.keyK, control: true),
          scope: WbShortcutScope.global,
        ),
        const WbShortcut(
          id: 'b.act',
          label: '动作 B',
          activator: SingleActivator(LogicalKeyboardKey.keyK, control: true),
          scope: WbShortcutScope.global,
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HotkeySettings(shortcuts: conflicted),
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('hotkey-conflict-banner')),
        findsOneWidget,
      );
      expect(find.textContaining('Ctrl+K'), findsWidgets);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HotkeySettings(shortcuts: WbShortcutService.defaults),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('hotkey-conflict-clear')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('hotkey-conflict-banner')),
        findsNothing,
      );
    });

    testWidgets('HotkeySettings：录制新键位并恢复默认', (WidgetTester tester) async {
      _useLargeViewport(tester);
      Map<String, List<String>> overrides = <String, List<String>>{};
      Future<void> pump() {
        return tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: HotkeySettings(
                  overrides: overrides,
                  onChanged: (String id, List<String> keys) {
                    overrides = <String, List<String>>{
                      ...overrides,
                      id: keys,
                    };
                  },
                  onReset: () => overrides = <String, List<String>>{},
                ),
              ),
            ),
          ),
        );
      }

      await pump();
      final MiuixArrowPreference reset =
          tester.widget<MiuixArrowPreference>(
        find.byKey(const ValueKey<String>('hotkey-reset')),
      );
      expect(reset.enabled, isFalse);

      await tester.tap(find.text('命令面板'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('hotkey-capture-dialog')),
        findsOneWidget,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
      await tester.pump();
      expect(find.text('Ctrl + P'), findsOneWidget);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byKey(const ValueKey<String>('hotkey-capture-confirm')));
      await tester.pumpAndSettle();
      expect(overrides['cmd.palette'], <String>['Ctrl', 'P']);

      await pump();
      expect(find.text('P'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey<String>('hotkey-reset')));
      await tester.pump();
      expect(overrides, isEmpty);
    });
  });
}
