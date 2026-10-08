/// 未保存改动三选对话框（保存 / 不保存 / 取消）。
///
/// 编辑页返回列表、打开其它文件前、主窗口关闭拦截（`app.dart`）三处共用；
/// 点外部 / Esc 关闭视为取消（不响应点外部，走显式按钮）。
library;

import 'package:flutter/material.dart';

import 'miuix_dialog.dart';

/// 未保存改动处理选择。
enum WbUnsavedChoice {
  /// 保存（保存成功后可继续离开 / 关闭）。
  save,

  /// 不保存（丢弃改动直接离开 / 关闭）。
  discard,

  /// 取消（留在当前界面 / 应用不关闭）。
  cancel,
}

/// 弹出未保存改动对话框（返回用户选择；对话框被系统关闭时回退取消）。
Future<WbUnsavedChoice> showUnsavedChangesDialog(
  BuildContext context, {
  String boardName = '',
  String message = '',
}) async {
  final String body = message.isNotEmpty
      ? message
      : boardName.isEmpty
          ? '当前白板有未保存的改动，要先保存吗？'
          : '「$boardName」有未保存的改动，要先保存吗？';
  final WbUnsavedChoice? choice = await showWbMiuixDialog<WbUnsavedChoice>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      return WbMiuixDialog(
        key: const ValueKey<String>('wb-unsaved-dialog'),
        title: '未保存的改动',
        summary: body,
        actions: <WbDialogAction>[
          WbDialogAction(
            key: const ValueKey<String>('wb-unsaved-cancel'),
            label: '取消',
            onPressed: () =>
                Navigator.of(context).pop(WbUnsavedChoice.cancel),
          ),
          WbDialogAction(
            key: const ValueKey<String>('wb-unsaved-discard'),
            label: '不保存',
            onPressed: () =>
                Navigator.of(context).pop(WbUnsavedChoice.discard),
          ),
          WbDialogAction(
            key: const ValueKey<String>('wb-unsaved-save'),
            label: '保存',
            primary: true,
            onPressed: () => Navigator.of(context).pop(WbUnsavedChoice.save),
          ),
        ],
      );
    },
  );
  return choice ?? WbUnsavedChoice.cancel;
}
