/// 跨端预览帧页匹配单测（协同 M3 Wave 0 / D3-0）。
///
/// 矩阵：同板全等 / 跨板同页序（-page-1 vs -page-1）真 / 跨板异页序
/// （-2 vs -1）假 / 引擎格式（page-N）跨命名空间同序真、异序假 /
/// 防误匹配（mypage-3 不入页序） / 空串、null、非 String（数字）透传真 /
/// 垃圾格式（'abc' vs 'def'；'abc-page-x'）假 / 一方无后缀假 / 多段后缀
/// 取最后一个匹配 / 空本机页 id 保守丢弃。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/collab/preview_page_match.dart';

void main() {
  group('previewPageMatches', () {
    test('同板全等：快速路径放行', () {
      expect(previewPageMatches('boardA-page-1', 'boardA-page-1'), isTrue);
      expect(previewPageMatches('page-1', 'page-1'), isTrue);
    });

    test('跨板同页序放行：命名空间不同但页序一致', () {
      expect(previewPageMatches('abc-page-1', 'def-page-1'), isTrue);
      expect(previewPageMatches('boardA-page-3', 'boardB-page-3'), isTrue);
    });

    test('跨板异页序丢弃：-page-2 vs -page-1', () {
      expect(previewPageMatches('abc-page-2', 'def-page-1'), isFalse);
      expect(previewPageMatches('abc-page-1', 'def-page-2'), isFalse);
    });

    test('引擎格式 page-N 兼容：跨命名空间同页序放行', () {
      // 引擎页 id（scene_store newPageId）无前缀连字符，与派生格式
      // `{boardId}-page-N` 跨端混用时按页序近似匹配。
      expect(previewPageMatches('page-2', 'def-page-2'), isTrue);
      expect(previewPageMatches('boardA-page-2', 'page-2'), isTrue);
      expect(previewPageMatches('page-1', 'page-1'), isTrue);
    });

    test('引擎格式 page-N 异页序丢弃', () {
      expect(previewPageMatches('page-2', 'page-1'), isFalse);
      expect(previewPageMatches('page-2', 'def-page-1'), isFalse);
      expect(previewPageMatches('abc-page-1', 'page-2'), isFalse);
    });

    test('防误匹配：page- 前紧邻字母数字不入页序', () {
      expect(previewPageMatches('mypage-3', 'boardB-page-1'), isFalse);
      expect(previewPageMatches('abc-page-1', 'mypage-1'), isFalse);
      expect(previewPageMatches('mypage-2', 'yourpage-2'), isFalse);
    });

    test('无 pageId 帧透传：空串 / null / 非 String', () {
      expect(previewPageMatches('', 'boardB-page-1'), isTrue);
      expect(previewPageMatches(null, 'boardB-page-1'), isTrue);
      expect(previewPageMatches(42, 'boardB-page-1'), isTrue);
      expect(
        previewPageMatches(<String, dynamic>{}, 'boardB-page-1'),
        isTrue,
      );
    });

    test('垃圾格式丢弃：无可比较页序', () {
      expect(previewPageMatches('abc', 'def'), isFalse);
      expect(previewPageMatches('abc-page-x', 'def-page-1'), isFalse);
      expect(previewPageMatches('room-42', 'boardB-page-1'), isFalse);
    });

    test('一方无后缀丢弃：仅单侧可提取页序', () {
      expect(previewPageMatches('abc-page-1', 'def'), isFalse);
      expect(previewPageMatches('abc-page-1', ''), isFalse);
    });

    test('多段后缀：贪婪取最后一个匹配', () {
      expect(previewPageMatches('a-page-1-page-2', 'b-page-2'), isTrue);
      expect(previewPageMatches('a-page-1-page-2', 'b-page-1'), isFalse);
    });
  });
}
