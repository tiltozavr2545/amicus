import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/sized_memory_image.dart';
import '../feed/comments_screen.dart';
import '../feed/create_post_screen.dart';
import '../feed/feed_repository.dart';
import '../notifications/push_deep_link.dart';
import '../notifications/push_notifications_repository.dart';
import '../notifications/user_activity_repository.dart';
import '../profile/profile_repository.dart';
import '../rooms/room_chat_screen.dart';

/// Destination index of the "new post" button in the bottom bar. It doesn't
/// correspond to a shell branch — tapping it pushes [CreatePostScreen] on top
/// instead of switching tabs.
///
/// Second from the left, with rooms in the middle: the bar reads
/// feed · new post · rooms · connections · profile.
const _addPostDestinationIndex = 1;

/// Branch indices in [routerProvider]'s shell — feed · rooms · connections ·
/// profile. Named because a tapped notification navigates by them, and a bare
/// `goBranch(2)` says nothing about where it lands.
const _feedBranchIndex = 0;
const _connectionsBranchIndex = 2;

/// Bottom-nav shell wrapping the four tab branches
/// (feed/rooms/connections/profile) registered on [routerProvider].
/// [navigationShell] preserves each branch's own navigation stack and
/// scroll/form state when switching tabs.
class MainShellScreen extends ConsumerStatefulWidget {
  const MainShellScreen({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static int _destinationIndexForBranch(int branchIndex) =>
      branchIndex < _addPostDestinationIndex ? branchIndex : branchIndex + 1;

  @override
  ConsumerState<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends ConsumerState<MainShellScreen> {
  /// Whether the composer is showing in place of [navigationShell].
  ///
  /// Composing used to push [CreatePostScreen] as its own route, which
  /// covers this whole [Scaffold] — including the bottom tab bar — because
  /// this widget builds directly under the router's own Navigator, with none
  /// of its own in between. Swapping `body` instead keeps that [Scaffold],
  /// and the tab bar with it, on screen while composing.
  bool _composing = false;

  void _closeCompose(bool created) {
    setState(() => _composing = false);
    if (created) ref.read(feedRefreshTickProvider.notifier).bump();
  }

  /// Opens what a tapped notification was about.
  ///
  /// Handled here rather than in each feature because this is the one widget
  /// that is always mounted while signed in — including on a cold start,
  /// where the tap arrives before any screen the target belongs to exists.
  /// The composer is closed first: landing on a chat with a half-written post
  /// still underneath would leave the tab bar pointing at the wrong place.
  void _openPushTarget(PushTarget target) {
    if (_composing) setState(() => _composing = false);
    final navigator = Navigator.of(context);
    switch (target) {
      case RoomChatTarget(:final roomId):
        navigator.push(
          MaterialPageRoute(builder: (_) => RoomChatScreen(roomId: roomId)),
        );
      case PostCommentsTarget(:final postId):
        navigator.push(
          MaterialPageRoute(builder: (_) => CommentsScreen(postId: postId)),
        );
      case ConnectionsTarget():
        widget.navigationShell.goBranch(_connectionsBranchIndex);
      case FeedTarget():
        // A branch switch, not a push: the feed is already at the bottom of
        // this stack, and pushing a second copy of it over itself would take
        // two backs to leave.
        widget.navigationShell.goBranch(_feedBranchIndex);
    }
  }

  /// The "profile" destination's icon: the user's own avatar once it's
  /// loaded, falling back to the generic person icon while it isn't (first
  /// frame, still loading, no photo set, or the fetch failed).
  Widget _profileIcon() {
    final avatarPath = ref.watch(myProfileProvider).value?.avatarPath;
    final avatarBytes = avatarPath == null
        ? null
        : ref.watch(avatarBytesProvider(avatarPath)).value;
    if (avatarBytes == null) return const Icon(Icons.person_outline);
    return CircleAvatar(
      radius: 12,
      backgroundImage: sizedMemoryImage(context, avatarBytes, logicalWidth: 24),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final navigationShell = widget.navigationShell;
    // Fire-and-forget: registers this device for push once per signed-in
    // user. Only reachable once already authenticated (router redirect), so
    // this is the natural single place to trigger it — no loading/error UI
    // needed, the provider itself is a no-op once already registered.
    ref.watch(pushRegistrationProvider);
    // Same fire-and-forget shape, right above: tells the server "the app was
    // just opened" so the digest push can count only posts that appeared
    // since — see notification_preferences' notify_digest and migration
    // 20260819190000.
    ref.watch(userActivityProvider);
    // Taps on notifications, cold start included. `listen` rather than
    // `watch`: this is an event to act on once, not state to paint.
    ref.listen(pushTapsProvider, (previous, next) {
      if (next.value case final target?) _openPushTarget(target);
    });
    return Scaffold(
      body: _composing
          // `canPop: false` scopes the back-button interception to exactly
          // while the composer is showing, instead of a permanent PopScope
          // on the shell that would swallow "back exits the app" from the
          // home tab too.
          ? PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) {
                if (!didPop) _closeCompose(false);
              },
              child: CreatePostScreen(onClose: _closeCompose),
            )
          : navigationShell,
      bottomNavigationBar: NavigationBar(
        // Icons only. The labels stay in the tree (`label` is what a screen
        // reader announces and what the long-press tooltip shows), they are
        // just not painted — five of them across a phone would either wrap or
        // shrink to unreadable.
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        selectedIndex: _composing
            ? _addPostDestinationIndex
            : MainShellScreen._destinationIndexForBranch(
                navigationShell.currentIndex,
              ),
        onDestinationSelected: (index) {
          if (index == _addPostDestinationIndex) {
            setState(() => _composing = true);
            return;
          }
          // Leaving the tab underneath the composer without saving; there is
          // no draft to preserve once it's gone from screen.
          if (_composing) setState(() => _composing = false);
          final branchIndex = index < _addPostDestinationIndex
              ? index
              : index - 1;
          navigationShell.goBranch(
            branchIndex,
            initialLocation: branchIndex == navigationShell.currentIndex,
          );
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home),
            label: l10n.feedTabLabel,
          ),
          NavigationDestination(
            icon: const Icon(Icons.add_circle_outline),
            label: l10n.newPostTitle,
          ),
          NavigationDestination(
            icon: const Icon(Icons.forum_outlined),
            selectedIcon: const Icon(Icons.forum),
            label: l10n.roomsTitle,
          ),
          NavigationDestination(
            icon: const Icon(Icons.people_outline),
            selectedIcon: const Icon(Icons.people),
            label: l10n.connectionsTitle,
          ),
          NavigationDestination(icon: _profileIcon(), label: l10n.profileTitle),
        ],
      ),
    );
  }
}
