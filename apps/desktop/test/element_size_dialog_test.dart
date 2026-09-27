/// 元素尺寸设置对话框（波次 C）Widget 测试：预填 / 校验 / 提交 / 取消。
///
/// 挂载模式对齐 `element_editor_test.dart` 的最小宿主约定（不启动完整
/// 应用，避免触发无关 Provider）；对话框只依赖 MaterialApp 与主题回退。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_desktop/widgets/canvas/element_size_dialog.dart';

/// 打开尺寸对话框的最小宿主；`results` 记录 pop 返回值。
Future<void> _openDialog(
  WidgetTester tester, {
  required double width,
  required double height,
  required List<(double, double)?> results,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              key: const ValueKey<String>('open-size-dialog'),
              onPressed: () async {
                results.add(
                  await showElementSizeDialog(
                    context,
                    width: width,
                    height: height,
                  ),
                );
              },
              child: const Text('打开尺寸设置'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey<String>('open-size-dialog')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey<String>('wb-size-dialog')), findsOneWidget);
}

/// 读取输入框当前文本。
String _fieldText(WidgetTester tester, String key) =>
    tester
        .widget<TextField>(find.byKey(ValueKey<String>(key)))
        .controller!
        .text;

void main() {
  testWidgets('预填当前尺寸（取整显示）', (WidgetTester tester) async {
    final List<(double, double)?> results = <(double, double)?>[];
    await _openDialog(tester, width: 320.4, height: 240.6, results: results);

    expect(find.text('尺寸设置'), findsOneWidget);
    expect(_fieldText(tester, 'wb-size-width-field'), '320');
    expect(_fieldText(tester, 'wb-size-height-field'), '241');
  });

  testWidgets('输入合法值确认：返回 (宽, 高)', (WidgetTester tester) async {
    final List<(double, double)?> results = <(double, double)?>[];
    await _openDialog(tester, width: 300, height: 200, results: results);

    await tester.enterText(
      find.byKey(const ValueKey<String>('wb-size-width-field')),
      '512',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('wb-size-height-field')),
      '384',
    );
    await tester.tap(find.byKey(const ValueKey<String>('wb-size-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('wb-size-dialog')), findsNothing);
    expect(results.single, (512.0, 384.0));
  });

  testWidgets('非法输入（0 / 空 / 非数字）：确认按钮禁用', (WidgetTester tester) async {
    final List<(double, double)?> results = <(double, double)?>[];
    await _openDialog(tester, width: 300, height: 200, results: results);

    final Finder widthField =
        find.byKey(const ValueKey<String>('wb-size-width-field'));
    final Finder confirm =
        find.byKey(const ValueKey<String>('wb-size-confirm'));

    FilledButton confirmButton() => tester.widget<FilledButton>(confirm);

    // 0：禁用。
    await tester.enterText(widthField, '0');
    await tester.pump();
    expect(confirmButton().onPressed, isNull, reason: '宽为 0 应禁用');

    // 空：禁用。
    await tester.enterText(widthField, '');
    await tester.pump();
    expect(confirmButton().onPressed, isNull, reason: '宽为空应禁用');

    // 非数字：禁用。
    await tester.enterText(widthField, 'abc');
    await tester.pump();
    expect(confirmButton().onPressed, isNull, reason: '非数字应禁用');

    // 恢复合法值：启用。
    await tester.enterText(widthField, '320');
    await tester.pump();
    expect(confirmButton().onPressed, isNotNull);
  });

  testWidgets('Enter 提交：校验通过 pop 结果', (WidgetTester tester) async {
    final List<(double, double)?> results = <(double, double)?>[];
    await _openDialog(tester, width: 300, height: 200, results: results);

    await tester.enterText(
      find.byKey(const ValueKey<String>('wb-size-width-field')),
      '640',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('wb-size-height-field')),
      '480',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('wb-size-dialog')), findsNothing);
    expect(results.single, (640.0, 480.0));
  });

  testWidgets('取消：返回 null', (WidgetTester tester) async {
    final List<(double, double)?> results = <(double, double)?>[];
    await _openDialog(tester, width: 300, height: 200, results: results);

    await tester.tap(find.byKey(const ValueKey<String>('wb-size-cancel')));
    await tester.pumpAndSettle();

    expect(results.single, isNull);
  });
}
