/// 设置持久化：`WbLocalStore` / `WbSettingsStore`（`settings.json` 落盘 +
/// 重启恢复）/ `WbAiSettings.build` 工厂 / 主题服务注入 sink 的写读闭环；
/// 无 sink 时保持纯内存（既有测试口径零影响）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_ai/ai_client.dart';
import 'package:whiteboard_desktop/services/local_store.dart';
import 'package:whiteboard_desktop/services/settings_store.dart';
import 'package:whiteboard_desktop/services/theme_service.dart';
import 'package:whiteboard_desktop/state/theme_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('wb_settings_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 模拟重启：同一目录新建存储实例（读同一 `settings.json`）。
  WbSettingsStore reopen({int maxRecentBoards = 20}) => WbSettingsStore(
        localStore: WbLocalStore(baseDirOverride: tempDir.path),
        maxRecentBoards: maxRecentBoards,
      );

  group('WbLocalStore', () {
    test('注入目录：路径拼接与 JSON 读写作', () {
      final WbLocalStore local = WbLocalStore(baseDirOverride: tempDir.path);
      expect(local.baseDir, tempDir.path);
      expect(
        local.pathFor('a.json'),
        '${tempDir.path}${Platform.pathSeparator}a.json',
      );
      expect(local.pathFor(''), '');

      expect(local.writeJson('a.json', <String, dynamic>{'k': 1}), isTrue);
      expect(local.readJson('a.json'), <String, dynamic>{'k': 1});
    });

    test('文件缺失 / 坏 JSON / 非对象内容返回 null', () {
      final WbLocalStore local = WbLocalStore(baseDirOverride: tempDir.path);
      expect(local.readJson('missing.json'), isNull);

      local.writeJson('bad.json', <String, dynamic>{}); // 先建目录
      File(local.pathFor('bad.json')).writeAsStringSync('{broken');
      expect(local.readJson('bad.json'), isNull);

      File(local.pathFor('arr.json')).writeAsStringSync('[1, 2]');
      expect(local.readJson('arr.json'), isNull);
    });
  });

  group('WbSettingsStore', () {
    test('全新存储：默认值且只读不落盘', () {
      final WbSettingsStore store = reopen();
      expect(store.themeId, '');
      expect(store.appearance, const WbAppearancePrefs());
      expect(store.ai, isNull);
      expect(store.syncServerUrl, '');
      expect(store.recentBoards, isEmpty);
      expect(File(store.settingsPath).existsSync(), isFalse);
    });

    test('主题 / 外观 / AI / 协作写读往返（模拟重启恢复）', () {
      final WbSettingsStore store = reopen();
      store.themeId = 'minimal';
      final WbAppearancePrefs prefs = const WbAppearancePrefs().copyWith(
        fontScale: 1.25,
        iconStyle: 'minimal',
        highContrast: true,
      );
      store.appearance = prefs;
      store.ai = const WbAiSettings(
        kind: WbAiSettings.kindAnthropic,
        apiKey: 'sk-test',
        model: 'claude-x',
      );
      store.syncServerUrl = 'ws://127.0.0.1:9000';

      final WbSettingsStore reopened = reopen();
      expect(reopened.themeId, 'minimal');
      expect(reopened.appearance, prefs);
      expect(reopened.ai?.kind, WbAiSettings.kindAnthropic);
      expect(reopened.ai?.apiKey, 'sk-test');
      expect(reopened.ai?.model, 'claude-x');
      expect(reopened.syncServerUrl, 'ws://127.0.0.1:9000');
    });

    test('ai 置 null：移除配置并落盘', () {
      final WbSettingsStore store = reopen();
      store.ai = const WbAiSettings(apiKey: 'k');
      expect(store.ai, isNotNull);
      store.ai = null;
      expect(store.ai, isNull);
      expect(reopen().ai, isNull);
    });

    test('最近列表：去重 / 最新在前 / 上限截断 / 移除 / 持久化', () {
      final WbSettingsStore capped = reopen(maxRecentBoards: 3);
      capped.rememberBoard(path: r'C:\boards\a.wbd', name: 'A');
      capped.rememberBoard(path: r'C:\boards\b.wbd', name: 'B');
      capped.rememberBoard(path: r'C:\boards\a.wbd', name: 'A2');
      expect(
        capped.recentBoards.map((WbRecentBoardEntry e) => e.path),
        <String>[r'C:\boards\a.wbd', r'C:\boards\b.wbd'],
      );
      expect(capped.recentBoards.first.name, 'A2');
      expect(capped.recentBoards.first.updatedAt, isNotEmpty);

      capped.rememberBoard(path: r'C:\boards\c.wbd');
      capped.rememberBoard(path: r'C:\boards\d.wbd');
      expect(capped.recentBoards.length, 3);
      expect(
        capped.recentBoards.map((WbRecentBoardEntry e) => e.path),
        <String>[r'C:\boards\d.wbd', r'C:\boards\c.wbd', r'C:\boards\a.wbd'],
      );

      capped.removeRecentBoard(r'C:\boards\c.wbd');
      expect(capped.recentBoards.length, 2);

      // 重启后保留（新实例读同一文件）。
      final WbSettingsStore reopened = reopen(maxRecentBoards: 3);
      expect(reopened.recentBoards.length, 2);
      expect(reopened.recentBoards.first.path, r'C:\boards\d.wbd');
    });

    test('设置文件损坏：全部回退默认并自愈写回', () {
      final WbSettingsStore store = reopen();
      File(store.settingsPath).parent.createSync(recursive: true);
      File(store.settingsPath).writeAsStringSync('{broken');

      final WbSettingsStore damaged = reopen();
      expect(damaged.themeId, '');
      expect(damaged.appearance, const WbAppearancePrefs());
      expect(damaged.recentBoards, isEmpty);

      damaged.themeId = 'dark-night';
      expect(reopen().themeId, 'dark-night');
    });
  });

  group('WbAiSettings', () {
    test('build：openai 分支与默认模型', () {
      final AiProvider provider = const WbAiSettings(apiKey: 'k').build();
      expect(provider, isA<OpenAiProvider>());
      final OpenAiProvider openai = provider as OpenAiProvider;
      expect(openai.apiKey, 'k');
      expect(openai.model, 'gpt-4o-mini');
    });

    test('build：anthropic 分支自定义模型', () {
      final AiProvider provider = const WbAiSettings(
        kind: WbAiSettings.kindAnthropic,
        apiKey: 'sk-a',
        model: 'claude-x',
      ).build();
      expect(provider, isA<AnthropicProvider>());
      expect((provider as AnthropicProvider).model, 'claude-x');
    });

    test('build：custom 分支 baseUrl 缺省回退默认', () {
      final AiProvider provider =
          const WbAiSettings(kind: WbAiSettings.kindCustom).build();
      expect(provider, isA<CustomProvider>());
      final CustomProvider custom = provider as CustomProvider;
      expect(custom.baseUrl, WbAiSettings.defaultCustomBaseUrl);
      expect(custom.model, 'internal-large');
    });

    test('fromJson：缺 kind 回退 openai；toJson 往返', () {
      expect(
        WbAiSettings.fromJson(<String, dynamic>{}).kind,
        WbAiSettings.kindOpenAi,
      );
      const WbAiSettings original = WbAiSettings(
        kind: WbAiSettings.kindCustom,
        apiKey: 'k',
        model: 'm',
        baseUrl: 'http://localhost:8080/v1',
      );
      final WbAiSettings round = WbAiSettings.fromJson(original.toJson());
      expect(round.kind, original.kind);
      expect(round.apiKey, original.apiKey);
      expect(round.model, original.model);
      expect(round.baseUrl, original.baseUrl);
    });
  });

  group('主题 / 外观注入持久化', () {
    test('WbThemeService(prefsSink)：构造即恢复主题与外观', () {
      final WbSettingsStore store = reopen();
      store.themeId = 'minimal';
      store.appearance = const WbAppearancePrefs().copyWith(
        fontScale: 1.25,
        highContrast: true,
      );

      final WbThemeService service = WbThemeService(prefsSink: store);
      expect(service.current.id, 'minimal');
      expect(service.persistedThemeId, 'minimal');
      expect(service.persistedAppearance.fontScale, 1.25);
      expect(service.persistedAppearance.highContrast, isTrue);
      service.dispose();
    });

    test('显式 initialThemeId 优先于持久化值', () {
      final WbSettingsStore store = reopen();
      store.themeId = 'minimal';
      final WbThemeService service = WbThemeService(
        initialThemeId: 'dark-night',
        prefsSink: store,
      );
      expect(service.current.id, 'dark-night');
      service.dispose();
    });

    test('select / saveAppearance 即时落盘', () {
      final WbSettingsStore store = reopen();
      final WbThemeService service = WbThemeService(prefsSink: store);
      service.select('blackboard');
      expect(store.themeId, 'blackboard');
      expect(reopen().themeId, 'blackboard');

      service.saveAppearance(
        service.persistedAppearance.copyWith(reduceMotion: true),
      );
      expect(reopen().appearance.reduceMotion, isTrue);
      service.dispose();
    });

    test('无 sink：纯内存不落盘', () {
      final WbThemeService service = WbThemeService(initialThemeId: 'minimal');
      service.select('dark-night');
      service.saveAppearance(
        service.persistedAppearance.copyWith(fontScale: 1.1),
      );
      expect(service.persistedThemeId, 'dark-night');
      expect(service.persistedAppearance.fontScale, 1.1);
      expect(tempDir.listSync(), isEmpty);
      service.dispose();
    });

    test('WbThemeState(store)：构造恢复；applyAppearance 落盘', () {
      final WbSettingsStore store = reopen();
      store.themeId = 'minimal';
      store.appearance = const WbAppearancePrefs().copyWith(fontScale: 1.25);

      final WbThemeState state = WbThemeState(store: store);
      expect(state.current.id, 'minimal');
      expect(state.appearance.fontScale, 1.25);

      state.applyAppearance(
        state.appearance.copyWith(
          backgroundFollowTheme: false,
          backgroundOpacity: 0.8,
        ),
      );
      expect(reopen().appearance.backgroundOpacity, 0.8);
      expect(reopen().appearance.backgroundFollowTheme, isFalse);
      state.dispose();
    });
  });
}
