/// 快捷键卡片弹层入口（命令面板 / 宿主共用）。
///
/// [WbShortcutCard] 本身是无外壳的内容卡片；本文件为其提供统一的
/// 模态展示方式（点外部关闭），供命令面板与宿主按钮复用。
library;

import 'package:flutter/material.dart';

import 'shortcut_card.dart';

/// 以模态对话框展示快捷键卡片，返回对话框关闭后完成的 Future。
Future<void> showShortcutCard(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) {
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
          child: const SingleChildScrollView(
            child: WbShortcutCard(),
          ),
        ),
      );
    },
  );
}
