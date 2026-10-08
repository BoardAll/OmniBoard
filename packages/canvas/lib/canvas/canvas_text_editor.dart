/// 画布文本编辑浮层：跟随元素位置与缩放的内联输入框。
///
/// - 便签 / 文本元素进入编辑时显示（由 [WbCanvasController.editingElementId]
///   驱动）；
/// - 输入实时写入模型（`updateEditingText`），绘制层即时预览；
/// - `Esc` / `Ctrl(Cmd)+Enter` / 点击外部 / 失焦 提交；空文本由
///   `endTextEditing` 清理元素。
///
/// 该组件通过 [AnimatedBuilder] 监听控制器；`Positioned` 与 `Stack` 之间
/// 仅有 widget 层（无 RenderObject），符合 ParentDataWidget 的使用约束。
///
/// 注意：即使处于空态也**必须**返回 `Positioned`（0 尺寸收缩）——该组件
/// 是 `Stack` 的直接子项，若返回非 positioned 的 `SizedBox.shrink()`，
/// Stack 会以非 positioned 子项的最大尺寸（0x0）作为自身尺寸，导致全画布
/// 布局错位、命中测试失效。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whiteboard_theme/theme.dart';

import 'canvas_controller.dart';
import 'canvas_model.dart';

/// 画布内联文本编辑器（overlay 层）。
class WbCanvasTextEditor extends StatelessWidget {
  /// 创建编辑器浮层。
  const WbCanvasTextEditor({super.key, required this.controller});

  /// 画布控制器（读取编辑元素、坐标换算、提交编辑）。
  final WbCanvasController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final WbCanvasElement? element = controller.editingElement;
        if (element == null) {
          // 空态保持 0 尺寸 Positioned，避免 Stack 尺寸坍缩（见文件头注释）。
          return const Positioned(
            left: 0,
            top: 0,
            child: SizedBox.shrink(),
          );
        }
        final Rect screen = controller.worldRectToScreen(element.bounds);
        return Positioned(
          left: screen.left,
          top: screen.top,
          width: screen.width,
          height: screen.height,
          child: _CanvasTextField(
            key: ValueKey<String>(element.id),
            controller: controller,
            element: element,
          ),
        );
      },
    );
  }
}

/// 单个元素的编辑输入框（随元素 id 变化重建）。
class _CanvasTextField extends StatefulWidget {
  const _CanvasTextField({
    super.key,
    required this.controller,
    required this.element,
  });

  final WbCanvasController controller;
  final WbCanvasElement element;

  @override
  State<_CanvasTextField> createState() => _CanvasTextFieldState();
}

class _CanvasTextFieldState extends State<_CanvasTextField> {
  late final TextEditingController _text;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.element.text);
    _focus = FocusNode(debugLabel: 'wb-canvas-text-editor');
    _focus.addListener(_handleFocusChanged);
    // 挂载后请求焦点（等首帧渲染完成，避免与 canvas Focus 竞争）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_handleFocusChanged);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!_focus.hasFocus) {
      // 失焦即提交（幂等：与 onTapOutside / Esc 可能重复触发）。
      widget.controller.endTextEditing();
    }
  }

  void _commit() {
    widget.controller.commitTextEditing(_text.text);
  }

  @override
  Widget build(BuildContext context) {
    final WbThemeColors colors = context.wbColors;
    final WbCanvasElement element = widget.element;
    final bool isNote = element.type == WbElementKind.note;
    final double scale = widget.controller.scale;
    final double fontSize = (isNote
            ? WbCanvasPalette.noteFontSize
            : WbCanvasPalette.textFontSize) *
        scale;

    final TextField field = TextField(
      controller: _text,
      focusNode: _focus,
      maxLines: null,
      style: TextStyle(
        fontSize: fontSize,
        height: isNote ? 1.35 : 1.3,
        color: isNote
            ? const Color(WbCanvasPalette.textColor)
            : Color(element.color),
      ),
      cursorColor: colors.primary,
      cursorWidth: 1.5,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintText: '输入内容',
        hintStyle: TextStyle(
          fontSize: fontSize,
          color: const Color(WbCanvasPalette.mutedTextColor),
        ),
      ),
      onChanged: widget.controller.updateEditingText,
      onTapOutside: (PointerDownEvent event) =>
          widget.controller.endTextEditing(),
    );

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _commit,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _commit,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _commit,
      },
      child: isNote
          ? Padding(
              padding:
                  EdgeInsets.all(WbCanvasPalette.notePadding * scale),
              child: field,
            )
          : Align(alignment: Alignment.centerLeft, child: field),
    );
  }
}
