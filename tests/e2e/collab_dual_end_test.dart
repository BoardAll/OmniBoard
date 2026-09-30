/// tests/e2e「双端互见」场景（M1）—— 骨架资产自检。
///
/// 完整场景编排（启动 realtime :8790 → 桌面参与者 ×2 双进程真连互见 →
/// 互见 op 矩阵（插入 / 移动 / 删除 / 文本终态）→ Web 参与者（W1 成员 /
/// 状态）→ 断线重连恢复）由 Node 编排脚本执行（本包 `support/`）：
///
/// ```powershell
/// node tests/e2e/support/run_collab_dual_end.mjs                    # 全量
/// node tests/e2e/support/run_collab_dual_end.mjs --only=server,ops  # 分段（无 GUI 环境）
/// node tests/e2e/support/run_collab_dual_end.mjs --list             # 段说明
/// ```
///
/// 运行前置与分段说明见 `docs/modules/18-qa-testing.md`（M1 协同测试资产索引）。
///
/// 本文件在默认 `flutter test` 中**恒可运行**（无外部依赖）：只做场景资产
/// 自检——防止骨架引用的复用资产（T1.6 双进程用例 / T1.8 浏览器冒烟 /
/// fixture 板）被移动、改名后静默失效；真正的双端真连执行在编排脚本内。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('M1 双端互见场景骨架', () {
    test('复用资产与编排脚本存在（双进程 / Web 冒烟 / 场景脚本）', () {
      const List<String> assets = <String>[
        'support/run_collab_dual_end.mjs',
        'support/wb_collab_scenario_probe.mjs',
        '../../apps/desktop/test/integration/ffi_sync_dual_process_test.dart',
        '../../apps/desktop/test/integration/support/run_dual_process_ffi_test.mjs',
        '../../apps/desktop/test/integration/support/wb_realtime_probe.mjs',
        '../../apps/web/test/realtime_web_smoke_test.dart',
      ];
      for (final String path in assets) {
        expect(File(path).existsSync(), isTrue, reason: '场景资产缺失：$path');
      }
    });

    test('fixture 板（boards/empty、boards/simple）可解析且含页面', () {
      for (final String name in const <String>['empty', 'simple']) {
        final File file = File('../fixture/boards/$name.json');
        expect(file.existsSync(), isTrue, reason: 'fixture 缺失：${file.path}');
        final Object? decoded = jsonDecode(file.readAsStringSync());
        expect(decoded, isA<Map<String, dynamic>>(), reason: name);
        final Map<String, dynamic> board = decoded! as Map<String, dynamic>;
        expect(board['id'], isA<String>(), reason: name);
        expect(board['pages'], isA<List<dynamic>>(), reason: name);
        expect((board['pages']! as List<dynamic>).isNotEmpty, isTrue, reason: name);
      }
    });
  });
}
