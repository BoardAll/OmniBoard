/// 跟随控制器（协同 M3 / T3.2）：跟随状态机 + 远端跟随帧消费。
///
/// 链路（《互动白板实时协同设计文档》M3「跟随 / 演示」）：
/// - 发起 / 停止：[startFollow] 发 `interactive:follow {targetUserId}`，
///   [stopFollow] 发 `interactive:unfollow`；均无 ack（尽力而为）。
/// - 自动停止：目标离开房间（参与者名单求交）、本端用户视口手势
///   （[handleUserViewportGesture]）、用户本地切页
///   （[handleLocalPageChanged]）、本端被移出房间 / 连接断开
///   （[syncWithRoom]；断连为静默停止，不发 unfollow、不产生手动抑制）。
/// - 帧消费：[handlePreviews] 从 presence 预览批次里只取
///   `userId == followingUserId` 的 `page` / `viewport` 帧：
///   viewport → `canvas.applyRemoteViewport`；page → 从帧 pageId 提取页序
///   （`-page-(\d+)$`，见 `preview_page_match.dart`），切到本地同页序
///   页面；本地无同页序页面时忽略切页（后续 viewport 帧继续同步视口）；
///   无 pageId 的切页帧不支持（保守忽略）。
/// - present 自动跟随：[syncWithRoom] 检测 `mode=present` 且演示者非本端
///   时自动 [startFollow]；手动 / 自动停止过的演示者不重复触发
///   （present 结束或演示者变更后恢复）。
///
/// 依赖注入：[collab]（请求出口 + 房间状态）、[canvas]（视口应用）、
/// [pageState]（页序查找与切页；未注入时仅同步视口）。
library;

import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:whiteboard_core/wb_core.dart';

import '../services/sync_service.dart';
import '../widgets/canvas/canvas_controller.dart';
import '../widgets/collab/preview_page_match.dart';
import 'page_state.dart';

/// 跟随控制器（应用侧协调器；状态变化经 ChangeNotifier 通知 UI）。
class WbFollowController extends ChangeNotifier {
  WbFollowController({
    required this.collab,
    required this.canvas,
    WbPageState? pageState,
  }) : _pageState = pageState;

  /// 协同服务（发 follow / unfollow + 读房间状态）。
  final WbCollabService collab;

  /// 画布控制器（远端视口应用入口）。
  final WbCanvasController canvas;

  final WbPageState? _pageState;

  String _followingUserId = '';
  String _suppressedPresenterId = '';
  String _expectedPageId = '';

  /// 正在跟随的目标 userId（未跟随为空串）。
  String get followingUserId => _followingUserId;

  /// 是否跟随中。
  bool get isFollowing => _followingUserId.isNotEmpty;

  /// 开始跟随（同一目标重复调用幂等；切换目标先停旧）。
  void startFollow(String userId) {
    if (userId.isEmpty || userId == _followingUserId) {
      return;
    }
    final String previous = _followingUserId;
    _followingUserId = userId;
    _expectedPageId = '';
    if (previous.isNotEmpty) {
      collab.unfollow(previous); // 切换目标：先停旧（无 ack，尽力而为）。
    }
    collab.follow(userId);
    notifyListeners();
  }

  /// 停止跟随（发 `interactive:unfollow`；幂等）。
  ///
  /// 停止后抑制当前演示者的自动跟随（present 会话变化后恢复）；
  /// 目标离开 / 切页 / 手势打断等自动停止也经此入口。
  void stopFollow() {
    final String target = _followingUserId;
    if (target.isEmpty) {
      return;
    }
    _followingUserId = '';
    _expectedPageId = '';
    _suppressedPresenterId = target;
    collab.unfollow(target);
    notifyListeners();
  }

  /// 用户视口手势（pan / zoom）入口：跟随中 → 打断。
  void handleUserViewportGesture() {
    if (_followingUserId.isEmpty) {
      return;
    }
    stopFollow();
  }

  /// 本地切页入口（画布 `onPagePreview` 汇聚点转发）。
  ///
  /// 跟随驱动的程序化切页（[startFollow] 后由 page 帧触发）不打断；
  /// 用户主动切页 → 自动停止跟随。
  void handleLocalPageChanged(String pageId) {
    if (_followingUserId.isEmpty) {
      _expectedPageId = '';
      return;
    }
    if (pageId.isNotEmpty && pageId == _expectedPageId) {
      _expectedPageId = ''; // 跟随驱动的切页：消费标记，不打断。
      return;
    }
    stopFollow(); // 用户本地切页：打断跟随。
  }

  /// 消费 presence 预览批次：只应用被跟随者的 `page` / `viewport` 帧。
  void handlePreviews(List<dynamic> previews) {
    final String target = _followingUserId;
    if (target.isEmpty || previews.isEmpty) {
      return;
    }
    for (final Object? preview in previews) {
      if (preview is! Map || preview['userId'] != target) {
        continue; // 只消费被跟随者的帧（服务端附加权威 userId）。
      }
      switch (preview['kind']) {
        case 'viewport':
          _applyViewportFrame(preview);
        case 'page':
          _applyPageFrame(preview);
        default:
          break;
      }
    }
  }

  /// 协同房间状态变化入口（宿主在 collab 通知时调用）。
  ///
  /// - 本端被移出房间 → 停止跟随（不再消费远端帧）；
  /// - 连接断开（离线 / 重连中）→ 静默停止跟随（不发 unfollow、
  ///   不产生手动抑制；重连后 present 会话未变化时可重新自动跟随）；
  /// - 跟随中且目标已离开 → 自动停止（名单为空时保守等待）；
  /// - present 模式且本端未跟随 → 自动跟随演示者。
  void syncWithRoom() {
    if (collab.isRemoved) {
      stopFollow();
      return;
    }
    if (!collab.isOnline && _followingUserId.isNotEmpty) {
      // 连接断开：静默停止跟随（不发 unfollow、不产生手动抑制）。
      _followingUserId = '';
      _expectedPageId = '';
      notifyListeners();
      return;
    }
    final String target = _followingUserId;
    if (target.isNotEmpty) {
      final List<WbCollabParticipant> participants = collab.participantList;
      bool online = false;
      for (final WbCollabParticipant participant in participants) {
        if (participant.id == target) {
          online = true;
          break;
        }
      }
      if (!online && participants.isNotEmpty) {
        stopFollow(); // 目标离开：自动停止。
        return;
      }
    }
    _maybeAutoFollow();
  }

  /// present 自动跟随（手动停止过的演示者不重复触发）。
  void _maybeAutoFollow() {
    if (!collab.presentMode) {
      _suppressedPresenterId = ''; // present 结束：解除抑制。
      return;
    }
    final String presenter = collab.presenterId;
    if (presenter.isEmpty || presenter == collab.selfUserId) {
      return; // 无演示者 / 本端即演示者。
    }
    if (_followingUserId.isNotEmpty) {
      return; // 已在跟随（不抢占手动目标）。
    }
    if (presenter == _suppressedPresenterId) {
      return; // 已手动 / 自动停止过该演示者：不重复自动触发。
    }
    startFollow(presenter);
  }

  /// 应用 viewport 帧（`{offset:{dx,dy}, zoom}`；坏载荷忽略）。
  void _applyViewportFrame(Map<dynamic, dynamic> frame) {
    final Object? rawOffset = frame['offset'];
    final Object? rawZoom = frame['zoom'];
    if (rawOffset is! Map || rawZoom is! num) {
      return;
    }
    final Object? dx = rawOffset['dx'];
    final Object? dy = rawOffset['dy'];
    if (dx is! num || dy is! num) {
      return;
    }
    canvas.applyRemoteViewport(
      Offset(dx.toDouble(), dy.toDouble()),
      rawZoom.toDouble(),
    );
  }

  /// 应用 page 帧（从帧 pageId 提取页序 → 切到本地同页序页面）。
  void _applyPageFrame(Map<dynamic, dynamic> frame) {
    final Object? rawPageId = frame['pageId'];
    if (rawPageId is! String || rawPageId.isEmpty) {
      return; // 无 pageId 的切页帧不支持。
    }
    final String? sequence = previewPageSequenceOf(rawPageId);
    if (sequence == null) {
      return;
    }
    _switchToSequence(sequence);
  }

  /// 切到本地同页序页面；无此页序时忽略切页（仅继续同步视口）。
  void _switchToSequence(String sequence) {
    final WbPageState? pages = _pageState;
    if (pages == null) {
      return;
    }
    for (final WbPage page in pages.pages) {
      if (previewPageSequenceOf(page.id) != sequence) {
        continue;
      }
      if (pages.currentPageId == page.id) {
        return; // 已在目标页：无需动作。
      }
      _expectedPageId = page.id; // 标记程序化切页，避免误判为打断。
      pages.select(page.id);
      return;
    }
    // 本地无同页序页面：忽略切页（后续 viewport 帧继续同步视口）。
  }
}
