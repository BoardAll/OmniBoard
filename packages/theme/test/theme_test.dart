import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_theme/theme.dart';

void main() {
  group('内置主题', () {
    test('9 个主题齐全，id 与顺序与 C++ kThemes 对齐', () {
      expect(WbBuiltinThemes.all.length, 9);
      expect(
        WbBuiltinThemes.all.map((WbThemeData t) => t.id).toList(),
        <String>[
          'clean-professional',
          'dark-night',
          'blackboard',
          'greenboard',
          'minimal',
          'hand-drawn',
          'cyber',
          'kids',
          'enterprise',
        ],
      );
    });

    test('默认主题为 clean-professional，色值与 C++ 一致', () {
      const WbThemeData t = WbBuiltinThemes.defaultTheme;
      expect(t.id, 'clean-professional');
      expect(t.name, '清爽专业');
      expect(t.dark, isFalse);
      expect(t.colors.primary, const Color(0xFF3370FF));
      expect(t.colors.canvas, const Color(0xFFF7F8FA));
      expect(t.colors.surface, const Color(0xFFFFFFFF));
      expect(t.colors.elevated, const Color(0xFFFFFFFF));
      expect(t.colors.icon, const Color(0xFF475467));
      expect(t.colors.hover, const Color(0xFFF2F4F7));
      expect(t.colors.border, const Color(0xFFE4E7EC));
      expect(t.radius.s, 4);
      expect(t.radius.m, 8);
      expect(t.radius.l, 12);
      expect(t.opacity.radial, 0.9);
      expect(t.opacity.toolbar, 0.95);
      expect(t.opacity.panel, 1.0);
    });

    test('dark 标志与查找', () {
      expect(WbBuiltinThemes.byId('dark-night')!.dark, isTrue);
      expect(WbBuiltinThemes.byId('blackboard')!.dark, isTrue);
      expect(WbBuiltinThemes.byId('greenboard')!.dark, isTrue);
      expect(WbBuiltinThemes.byId('cyber')!.dark, isTrue);
      expect(WbBuiltinThemes.byId('minimal')!.dark, isFalse);
      expect(WbBuiltinThemes.byId('hand-drawn')!.dark, isFalse);
      expect(WbBuiltinThemes.byId('missing'), isNull);
    });

    test('派生 token 默认规则（toolbar/radial/sidebar/card）', () {
      final WbThemeData t = WbBuiltinThemes.byId('dark-night')!;
      expect(t.colors.toolbarBackground, t.colors.elevated);
      expect(t.colors.radialBackground, t.colors.elevated);
      expect(t.colors.radialHighlight, t.colors.primary);
      expect(t.colors.sidebarBackground, t.colors.surface);
      expect(t.colors.toolbarActive, t.colors.primary);
      expect(t.colors.cardBackground, t.colors.elevated);
      expect(t.colors.cardHover, t.colors.hover);
      expect(t.colors.cardBorder, t.colors.border);
    });
  });

  group('JSON 往返', () {
    test('全部内置主题 toJson/fromJson 无损往返', () {
      for (final WbThemeData theme in WbBuiltinThemes.all) {
        final WbThemeData restored = WbThemeData.fromJson(theme.toJson());
        expect(restored, theme, reason: theme.id);
      }
    });

    test('toJson 输出 C++ BuildTheme 的 13 键 colors', () {
      final Map<String, String> colors =
          WbBuiltinThemes.defaultTheme.colors.toJson();
      expect(colors.length, 13);
      expect(colors['bg.canvas'], '#F7F8FA');
      expect(colors['bg.surface'], '#FFFFFF');
      expect(colors['bg.elevated'], '#FFFFFF');
      expect(colors['primary'], '#3370FF');
      expect(colors['toolbar.bg'], '#FFFFFF');
      expect(colors['toolbar.icon'], '#475467');
      expect(colors['toolbar.active'], '#3370FF');
      expect(colors['radial.bg'], '#FFFFFF');
      expect(colors['radial.highlight'], '#3370FF');
      expect(colors['sidebar.bg'], '#FFFFFF');
      expect(colors['card.bg'], '#FFFFFF');
      expect(colors['card.hover'], '#F2F4F7');
      expect(colors['card.border'], '#E4E7EC');
    });

    test('WbThemeLoader 解析/序列化单主题与主题包', () {
      final String json = WbThemeLoader.serialize(WbBuiltinThemes.kids);
      final WbThemeData? parsed = WbThemeLoader.parse(json);
      expect(parsed, isNotNull);
      expect(parsed!.id, 'kids');
      expect(parsed.name, '儿童');
      expect(parsed.colors.primary, const Color(0xFFFF6B9D));

      final String wrapped = '{"theme": $json}';
      expect(WbThemeLoader.parse(wrapped)?.id, 'kids');

      final String packJson =
          WbThemeLoader.serializePack(WbBuiltinThemes.pack);
      final WbThemePack? pack = WbThemeLoader.parsePack(packJson);
      expect(pack, isNotNull);
      expect(pack!.themes.length, 9);
      expect(pack.themeById('greenboard')?.name, '绿板');

      expect(WbThemeLoader.parse('not json'), isNull);
      expect(WbThemeLoader.parsePack('{"id":"x"}'), isNull);
    });
  });

  group('主题管理器', () {
    const WbThemeData custom = WbThemeData(
      id: 'my-theme',
      name: '我的主题',
      colors: WbThemeColors(
        canvas: Color(0xFF102030),
        surface: Color(0xFF203040),
        elevated: Color(0xFF304050),
        primary: Color(0xFF11AAFF),
        icon: Color(0xFFEEEEEE),
        hover: Color(0xFF405060),
        border: Color(0xFF506070),
      ),
    );

    test('切换/注册/移除自定义主题', () {
      final WbThemeManager manager = WbThemeManager();
      expect(manager.current.id, 'clean-professional');

      String? changed;
      manager.onThemeChanged = (String id) => changed = id;
      manager.setTheme('dark-night');
      expect(manager.current.id, 'dark-night');
      expect(changed, 'dark-night');

      manager.setTheme('unknown-id');
      expect(manager.current.id, 'clean-professional');

      manager.registerCustom(custom);
      expect(manager.current.id, 'my-theme');
      expect(manager.available.length, 10);
      expect(manager.customThemes.length, 1);

      expect(manager.removeCustom('my-theme'), isTrue);
      expect(manager.current.id, 'clean-professional');
      expect(manager.removeCustom('my-theme'), isFalse);
    });

    test('注册主题包与初始自定义主题', () {
      final WbThemeManager manager =
          WbThemeManager(initialThemeId: 'my-theme', customThemes: <WbThemeData>[custom]);
      expect(manager.current.id, 'my-theme');

      manager.registerPack(WbBuiltinThemes.pack);
      expect(manager.current.id, 'clean-professional');

      final WbThemeManager emptyPack =
          WbThemeManager(initialThemeId: 'missing');
      expect(emptyPack.current.id, 'clean-professional');
    });
  });

  group('Flutter 集成', () {
    testWidgets('toFlutterThemeData 挂载扩展，context.wbTheme 可取到', (WidgetTester tester) async {
      final WbThemeManager manager = WbThemeManager(initialThemeId: 'cyber');
      WbThemeData? seen;
      await tester.pumpWidget(
        MaterialApp(
          theme: manager.flutterThemeData,
          home: Builder(
            builder: (BuildContext context) {
              seen = context.wbTheme;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(seen, isNotNull);
      expect(seen!.id, 'cyber');
      expect(seen!.dark, isTrue);
      expect(seen!.colors.primary, const Color(0xFF00E5FF));
      expect(
        Theme.of(tester.element(find.byType(SizedBox)))
            .scaffoldBackgroundColor,
        const Color(0xFF0A0E27),
      );
    });
  });
}
