import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_icons/icons.dart';

void main() {
  group('WbIconStyle', () {
    test('id 稳定且从 id 解析往返一致', () {
      expect(WbIconStyle.linear.id, 'linear');
      expect(WbIconStyle.filled.id, 'filled');
      expect(WbIconStyle.minimal.id, 'minimal');
      expect(WbIconStyle.handDrawn.id, 'hand_drawn');
      expect(WbIconStyle.pixel.id, 'pixel');
      for (final WbIconStyle style in WbIconStyle.values) {
        expect(WbIconStyle.fromId(style.id), style);
      }
    });

    test('未知 id 回退到 linear', () {
      expect(WbIconStyle.fromId('no-such-style'), WbIconStyle.linear);
      expect(WbIconStyle.fromId(''), WbIconStyle.linear);
    });

    test('每个风格都有中文显示名', () {
      for (final WbIconStyle style in WbIconStyle.values) {
        expect(style.displayName, isNotEmpty);
      }
      expect(WbIconStyle.linear.displayName, '线性');
      expect(WbIconStyle.handDrawn.displayName, '手绘');
    });
  });

  group('图标集完整性', () {
    test('核心语义图标在各风格集内均非空且变体互不相同', () {
      // 编辑
      expect(LinearIcons.undo.codePoint, isNot(0));
      expect(LinearIcons.redo.codePoint, isNot(0));
      expect(FilledIcons.undo.codePoint, isNot(0));
      expect(MinimalIcons.undo.codePoint, isNot(0));
      expect(HandDrawnIcons.undo.codePoint, isNot(0));
      expect(PixelIcons.undo.codePoint, isNot(0));
      // outlined/filled/rounded 三种变体应是不同字形
      expect(LinearIcons.undo.codePoint, isNot(FilledIcons.undo.codePoint));
      expect(LinearIcons.undo.codePoint, isNot(MinimalIcons.undo.codePoint));
      expect(FilledIcons.undo.codePoint, isNot(MinimalIcons.undo.codePoint));
    });

    test('工具与内容模块图标可用', () {
      expect(LinearIcons.select.codePoint, isNot(0));
      expect(LinearIcons.pen.codePoint, isNot(0));
      expect(LinearIcons.text.codePoint, isNot(0));
      expect(LinearIcons.shape.codePoint, isNot(0));
      expect(LinearIcons.stickyNote.codePoint, isNot(0));
      expect(LinearIcons.flowchart.codePoint, isNot(0));
      expect(LinearIcons.mindmap.codePoint, isNot(0));
      expect(LinearIcons.table.codePoint, isNot(0));
      expect(LinearIcons.formula.codePoint, isNot(0));
    });

    test('视图与布局图标可用', () {
      expect(LinearIcons.zoomIn.codePoint, isNot(0));
      expect(LinearIcons.zoomOut.codePoint, isNot(0));
      expect(LinearIcons.fitScreen.codePoint, isNot(0));
      expect(LinearIcons.alignLeft.codePoint, isNot(0));
      expect(LinearIcons.distributeHorizontal.codePoint, isNot(0));
    });

    test('AI/状态/协作图标可用', () {
      expect(LinearIcons.ai.codePoint, isNot(0));
      expect(LinearIcons.mic.codePoint, isNot(0));
      expect(LinearIcons.send.codePoint, isNot(0));
      expect(LinearIcons.warning.codePoint, isNot(0));
      expect(LinearIcons.sync.codePoint, isNot(0));
      expect(LinearIcons.offline.codePoint, isNot(0));
      expect(LinearIcons.members.codePoint, isNot(0));
      expect(LinearIcons.permission.codePoint, isNot(0));
    });

    test('系统图标可用（power 各风格）', () {
      expect(LinearIcons.power.codePoint, isNot(0));
      expect(FilledIcons.power.codePoint, isNot(0));
      expect(MinimalIcons.power.codePoint, isNot(0));
      expect(HandDrawnIcons.power.codePoint, isNot(0));
      expect(PixelIcons.power.codePoint, isNot(0));
    });

    test('预留字体族名非空（hand_drawn / pixel）', () {
      expect(HandDrawnIcons.preferredFontFamily, isNotEmpty);
      expect(PixelIcons.preferredFontFamily, isNotEmpty);
    });
  });
}
