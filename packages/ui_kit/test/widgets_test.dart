import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whiteboard_icons/icons.dart';
import 'package:whiteboard_ui_kit/ui_kit.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('WbIcon 渲染指定图标与尺寸', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const WbIcon(LinearIcons.pen, size: 24)));
    final Icon icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, LinearIcons.pen);
    expect(icon.size, 24);

    await tester.pumpWidget(_host(const WbIcon(LinearIcons.undo)));
    expect(tester.widget<Icon>(find.byType(Icon)).size, WbIcon.defaultSize);
  });

  testWidgets('WbText 各变体映射对应字号', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const WbText('标题文本', variant: WbTextVariant.title)));
    Text text = tester.widget<Text>(find.text('标题文本'));
    expect(text.style?.fontSize, WbTypography.fontSizeMd);

    await tester.pumpWidget(_host(const WbText('正文', variant: WbTextVariant.body, color: Colors.red)));
    text = tester.widget<Text>(find.text('正文'));
    expect(text.style?.color, Colors.red);
    expect(text.style?.fontSize, WbTypography.fontSizeBase);
  });

  testWidgets('WbDivider 与 WbVerticalDivider 可渲染', (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      const Column(children: <Widget>[
        WbDivider(),
        SizedBox(
          height: 24,
          child: Row(children: <Widget>[
            Text('a'),
            WbVerticalDivider(),
            Text('b'),
          ]),
        ),
      ]),
    ));
    expect(find.byType(WbDivider), findsOneWidget);
    expect(find.byType(WbVerticalDivider), findsOneWidget);
  });

  testWidgets('WbBadge 计数超过上限显示 99+', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const WbBadge.count(150)));
    expect(find.text('99+'), findsOneWidget);

    await tester.pumpWidget(_host(const WbBadge.count(3)));
    expect(find.text('3'), findsOneWidget);

    await tester.pumpWidget(_host(const WbBadge.dot()));
    expect(find.byType(WbBadge), findsOneWidget);

    await tester.pumpWidget(_host(const WbBadge(label: '新')));
    expect(find.text('新'), findsOneWidget);
  });

  testWidgets('WbBadge 叠加在 child 右上角', (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      const WbBadge.count(2, child: Icon(Icons.notifications)),
    ));
    expect(find.byIcon(Icons.notifications), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('WbAvatar 中文取首字、英文取首字母', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const WbAvatar(name: '张三')));
    expect(find.text('张'), findsOneWidget);

    await tester.pumpWidget(_host(const WbAvatar(name: 'John Doe')));
    expect(find.text('JD'), findsOneWidget);

    await tester.pumpWidget(_host(const WbAvatar()));
    expect(find.text('?'), findsOneWidget);
  });

  testWidgets('WbProgressBar/Ring 渲染且支持不确定态', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const WbProgressBar(value: 0.5)));
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.5);

    await tester.pumpWidget(_host(const WbProgressBar()));
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, isNull);

    await tester.pumpWidget(_host(const WbProgressRing(value: 0.3)));
    expect(tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator)).value, 0.3);
  });

  testWidgets('WbSkeleton 动画帧推进且可安全卸载', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const WbSkeleton(width: 100, height: 12)));
    expect(find.byType(WbSkeleton), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // 多行文本骨架与圆形骨架
    await tester.pumpWidget(_host(const WbSkeletonText(lines: 3)));
    expect(find.byType(WbSkeleton), findsNWidgets(3));

    await tester.pumpWidget(_host(const WbSkeletonCircle()));
    expect(find.byType(WbSkeleton), findsOneWidget);

    // 卸载触发 AnimationController.dispose
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('WbImage.memory 未解码完成时显示加载占位', (WidgetTester tester) async {
    await tester.pumpWidget(_host(WbImage.memory(Uint8List.fromList(kTransparentPng))));
    expect(find.byType(WbImage), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('WbTag 渲染标签与图标', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const WbTag('已完成', icon: Icons.check)));
    expect(find.text('已完成'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });
}

/// 1×1 透明 PNG（标准 kTransparentImage 字节）。
const List<int> kTransparentPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
