import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../feed/create_post_screen.dart';
import '../feed/feed_repository.dart';
import '../notifications/push_notifications_repository.dart';
import '../notifications/user_activity_repository.dart';

/// Destination index of the "new post" button in the bottom bar. It doesn't
/// correspond to a shell branch — tapping it pushes [CreatePostScreen] on top
/// instead of switching tabs.
///
/// Second from the left, with rooms in the middle: the bar reads
/// feed · new post · rooms · connections · profile.
const _addPostDestinationIndex = 1;

/// Bottom-nav shell wrapping the four tab branches
/// (feed/rooms/connections/profile) registered on [routerProvider].
/// [navigationShell] preserves each branch's own navigation stack and
/// scroll/form state when switching tabs.
class MainShellScreen extends ConsumerWidget {
  const MainShellScreen({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static int _destinationIndexForBranch(int branchIndex) =>
      branchIndex < _addPostDestinationIndex ? branchIndex : branchIndex + 1;

  Future<void> _openCreatePost(BuildContext context, WidgetRef ref) async {
    final created = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const CreatePostScreen()));
    if (created == true) {
      ref.read(feedRefreshTickProvider.notifier).bump();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
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
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        // Icons only. The labels stay in the tree (`label` is what a screen
        // reader announces and what the long-press tooltip shows), they are
        // just not painted — five of them across a phone would either wrap or
        // shrink to unreadable.
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
        selectedIndex: _destinationIndexForBranch(navigationShell.currentIndex),
        onDestinationSelected: (index) {
          if (index == _addPostDestinationIndex) {
            _openCreatePost(context, ref);
            return;
          }
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
          NavigationDestination(
            icon: const Icon(Icons.person_outline),
            selectedIcon: const Icon(Icons.person),
            label: l10n.profileTitle,
          ),
        ],
      ),
    );
  }
}
