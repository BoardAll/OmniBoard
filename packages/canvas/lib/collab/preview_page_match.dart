/// 跨端预览帧页匹配（协同 M3 Wave 0 / D3-0）。
///
/// 背景：预览帧载荷 `pageId` 由发送端**本地页 id 命名空间**派生
/// （`page_state.dart` 的 `'$boardId-page-1'`，boardId 为发送端本地板
/// id），而入房 `WbCollabService.start(boardId: 房间号)` 用的是用户输入
/// 房间号（与本地板 id 无关联）——两端 pageId 命名空间不同，接收端原先的
/// 严格全等比较会把全部预览帧（ink 鬼影 / transform 叠加 / 远端光标 /
/// 远端选区）跨端误丢弃（"幽灵预览"不显示）。
///
/// 匹配口径（发送端载荷不变，向后兼容）：
/// - [framePageId] 非 String 或空串 → true（M2「帧无 pageId 透传」语义）；
/// - 与 [localPageId] 全等 → true（快速路径：同命名空间直接命中）；
/// - 否则双方均按 `page-(\d+)$` 提取页序（贪婪，取最后一个匹配；
///   `page-` 前须为串首或非字母数字，防 `mypage-3` 类误匹配），
///   均存在且相等 → true（「页序后缀近似」口径：页结构跨端尚未同步，
///   M3 跟随功能同口径）；
/// - 其余 → false（非当前页 / 无可比较页序：保守丢弃）。
///
/// 页序后缀兼容两种页 id 命名空间：
/// - 引擎格式 `page-N`（scene_store `newPageId()`，无前缀连字符——
///   修正前正则要求 `-page-N` 导致此类帧全量误丢弃）；
/// - 派生格式 `{boardId}-page-N`（演示 / 文件恢复路径）。
library;

/// 页序后缀（锚定结尾；多匹配时取最后一个）。
final RegExp _pageSequencePattern = RegExp(r'(?:^|[^0-9A-Za-z])page-(\d+)$');

/// 预览帧 pageId 是否属于本机当前页（跨端命名空间近似口径）。
///
/// 供画布预览入口（`canvas_controller.dart`）、在场层
/// （`remote_cursors.dart`）与跟随控制器（`follow_controller.dart`）
/// 共用，保证各处过滤语义一致。
bool previewPageMatches(Object? framePageId, String localPageId) {
  if (framePageId is! String || framePageId.isEmpty) {
    return true; // 无 pageId 帧：透传（M2 兼容）。
  }
  if (framePageId == localPageId) {
    return true; // 全等：快速路径。
  }
  final String? frameSequence = previewPageSequenceOf(framePageId);
  if (frameSequence == null) {
    return false;
  }
  return frameSequence == previewPageSequenceOf(localPageId);
}

/// 提取页序后缀（无匹配返回 null；多个匹配取最后一个）。
///
/// 跟随控制器用它把远端 `page` 帧的 pageId 映射到本地同页序页面。
String? previewPageSequenceOf(String pageId) {
  final Iterable<RegExpMatch> matches = _pageSequencePattern.allMatches(pageId);
  return matches.isEmpty ? null : matches.last.group(1);
}
