/// 未保存改动三选对话框（保存 / 不保存 / 取消）。
///
/// 编辑页返回列表、打开其它文件前、主窗口关闭拦截（`app.dart`）三处共用；
/// 点外部 / Esc 关闭视为取消（barrierDismissible = false，走显式按钮）。
library;

import 'package:flutter/material.dart';

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
  final WbUnsavedChoice? choice = await showDialog<WbUnsavedChoice>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      return AlertDialog(
        key: const ValueKey<String>('wb-unsaved-dialog'),
        title: const Text('未保存的改动'),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('wb-unsaved-cancel'),
            onPressed: () =>
                Navigator.of(context).pop(WbUnsavedChoice.cancel),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey<String>('wb-unsaved-discard'),
            onPressed: () =>
                Navigator.of(context).pop(WbUnsavedChoice.discard),
            child: const Text('不保存'),
          ),
          FilledButton(
            key: const ValueKey<String>('wb-unsaved-save'),
            onPressed: () => Navigator.of(context).pop(WbUnsavedChoice.save),
            child: const Text('保存'),
          ),
        ],
      );
    },
  );
  return choice ?? WbUnsavedChoice.cancel;
}
