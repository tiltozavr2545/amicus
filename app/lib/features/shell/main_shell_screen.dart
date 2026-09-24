import 'dart:io' show Platform;

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
  Widget _profileIcon(double iconSize) {
    final avatarPath = ref.watch(myProfileProvider).value?.avatarPath;
    final avatarBytes = avatarPath == null
        ? null
        : ref.watch(avatarBytesProvider(avatarPath)).value;
    if (avatarBytes == null) {
      return Icon(Icons.person_outline, size: iconSize);
    }
    return CircleAvatar(
      radius: iconSize / 2,
      backgroundImage: sizedMemoryImage(
        context,
        avatarBytes,
        logicalWidth: iconSize,
      ),
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
      bottomNavigationBar: _bottomNavigationBar(l10n, navigationShell),
    );
  }

  int _selectedIndex(StatefulNavigationShell navigationShell) => _composing
      ? _addPostDestinationIndex
      : MainShellScreen._destinationIndexForBranch(
          navigationShell.currentIndex,
        );

  void _onDestinationSelected(
    int index,
    StatefulNavigationShell navigationShell,
  ) {
    if (index == _addPostDestinationIndex) {
      setState(() => _composing = true);
      return;
    }
    // Leaving the tab underneath the composer without saving; there is
    // no draft to preserve once it's gone from screen.
    if (_composing) setState(() => _composing = false);
    final branchIndex = index < _addPostDestinationIndex ? index : index - 1;
    navigationShell.goBranch(
      branchIndex,
      initialLocation: branchIndex == navigationShell.currentIndex,
    );
  }

  /// The bottom bar's icons/labels, shared between the iOS-only [_BottomBar]
  /// and Android's stock [NavigationBar] below — only the *container*
  /// differs per platform, not what's in it.
  List<_BottomBarDestination> _destinations(AppLocalizations l10n) => [
    _BottomBarDestination(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
      label: l10n.feedTabLabel,
    ),
    _BottomBarDestination(
      icon: Icons.add_circle_outline,
      label: l10n.newPostTitle,
    ),
    _BottomBarDestination(
      icon: Icons.forum_outlined,
      selectedIcon: Icons.forum,
      label: l10n.roomsTitle,
    ),
    _BottomBarDestination(
      icon: Icons.people_outline,
      selectedIcon: Icons.people,
      label: l10n.connectionsTitle,
    ),
    _BottomBarDestination(iconBuilder: _profileIcon, label: l10n.profileTitle),
  ];

  /// iOS gets the custom [_BottomBar] (IMM-195: [NavigationBar] bakes in an
  /// asymmetric icon row that no wrapping can fix — see its doc comment).
  /// Android's [NavigationBar] never had that asymmetry (no home-indicator
  /// safe-area to expose it) and the IMM-195 ticket required Android's bar
  /// to stay unchanged, so Android keeps using the stock widget.
  Widget _bottomNavigationBar(
    AppLocalizations l10n,
    StatefulNavigationShell navigationShell,
  ) {
    final selectedIndex = _selectedIndex(navigationShell);
    void onSelected(int index) =>
        _onDestinationSelected(index, navigationShell);
    if (Platform.isIOS) {
      return _BottomBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: onSelected,
        destinations: _destinations(l10n),
      );
    }
    return NavigationBar(
      // Icons only. The labels stay in the tree (`label` is what a screen
      // reader announces and what the long-press tooltip shows), they are
      // just not painted — five of them across a phone would either wrap or
      // shrink to unreadable.
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelected,
      destinations: [
        for (final destination in _destinations(l10n))
          NavigationDestination(
            icon: destination.iconBuilder?.call(24) ?? Icon(destination.icon),
            selectedIcon:
                destination.iconBuilder?.call(24) ??
                (destination.selectedIcon == null
                    ? null
                    : Icon(destination.selectedIcon)),
            label: destination.label,
          ),
      ],
    );
  }
}

/// One tappable entry in [_BottomBar]. Either a Material [icon] (with an
/// optional [selectedIcon] variant), or a fully custom [iconWidget] (the
/// profile avatar) — never both.
class _BottomBarDestination {
  const _BottomBarDestination({
    this.icon,
    this.selectedIcon,
    this.iconBuilder,
    required this.label,
  }) : assert(
         icon != null || iconBuilder != null,
         'a destination needs either icon or iconBuilder',
       );

  final IconData? icon;
  final IconData? selectedIcon;
  final Widget Function(double iconSize)? iconBuilder;
  final String label;
}

/// A from-scratch bottom tab bar, replacing Material's [NavigationBar].
///
/// [NavigationBar] bakes in an asymmetric icon row: it reserves space below
/// the icon for a label even with [NavigationDestinationLabelBehavior
/// .alwaysHide], so the icon row itself sits closer to the top than the
/// bottom no matter how the surrounding padding or safe area is adjusted
/// (IMM-195). Building the bar directly gives full control over that
/// spacing: an explicit, symmetric [_verticalPadding] around the icon row,
/// with the bottom safe area reserved *outside* it via [SafeArea] and zero
/// gap in between.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final List<_BottomBarDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  static const _verticalPadding = 12.0;
  static const _phoneIconSize = 26.0;
  static const _tabletIconSize = 38.0;
  // iPad's own multitasking-window breakpoint (see Scaffold.of usage
  // elsewhere); anything narrower is a phone, however large its pixel count.
  static const _tabletShortestSide = 600.0;

  @override
  Widget build(BuildContext context) {
    final navBarTheme = NavigationBarTheme.of(context);
    final colorScheme = ColorScheme.of(context);
    final backgroundColor =
        navBarTheme.backgroundColor ?? colorScheme.surfaceContainer;
    final indicatorColor =
        navBarTheme.indicatorColor ?? colorScheme.secondaryContainer;
    final selectedColor =
        navBarTheme.iconTheme?.resolve({WidgetState.selected})?.color ??
        colorScheme.onSecondaryContainer;
    final unselectedColor =
        navBarTheme.iconTheme?.resolve(const {})?.color ??
        colorScheme.onSurfaceVariant;
    final isTablet =
        MediaQuery.sizeOf(context).shortestSide >= _tabletShortestSide;
    final iconSize = isTablet ? _tabletIconSize : _phoneIconSize;
    return ColoredBox(
      color: backgroundColor,
      // Reserves the bottom inset (home indicator / iPad window chrome)
      // *outside* the padded icon row below, rather than growing the row's
      // own padding — that is what keeps the space above and below the
      // icons equal regardless of the device's safe area.
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(
            // A hair more on top than bottom: at this padding scale the
            // rendered result reads as visually equal — matching pixels
            // exactly left the top looking very slightly shy (Madrus,
            // IMM-195 verification pass).
            top: _verticalPadding + 8,
            bottom: _verticalPadding,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final (index, destination) in destinations.indexed)
                _BottomBarIcon(
                  destination: destination,
                  selected: index == selectedIndex,
                  iconSize: iconSize,
                  indicatorColor: indicatorColor,
                  selectedColor: selectedColor,
                  unselectedColor: unselectedColor,
                  onTap: () => onDestinationSelected(index),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBarIcon extends StatelessWidget {
  const _BottomBarIcon({
    required this.destination,
    required this.selected,
    required this.iconSize,
    required this.indicatorColor,
    required this.selectedColor,
    required this.unselectedColor,
    required this.onTap,
  });

  final _BottomBarDestination destination;
  final bool selected;
  final double iconSize;
  final Color indicatorColor;
  final Color selectedColor;
  final Color unselectedColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon =
        destination.iconBuilder?.call(iconSize) ??
        Icon(
          selected
              ? (destination.selectedIcon ?? destination.icon)
              : destination.icon,
          size: iconSize,
          color: selected ? selectedColor : unselectedColor,
        );
    // Fixed width/height rather than symmetric padding: padding only
    // guarantees centering if nothing upstream (InkResponse's own minimum
    // tap-target inset, in particular) nudges the box afterwards. A pinned
    // size plus `Center` centers the icon unconditionally, independent of
    // whatever wraps it outside — which is what "not vertically centered"
    // on the selected pill turned out to need (IMM-195).
    final pillWidth = iconSize * 2;
    final pillHeight = iconSize * 1.5;
    return Tooltip(
      message: destination.label,
      child: Semantics(
        button: true,
        selected: selected,
        label: destination.label,
        child: InkResponse(
          onTap: onTap,
          radius: iconSize,
          child: Container(
            width: pillWidth,
            height: pillHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? indicatorColor : Colors.transparent,
              borderRadius: BorderRadius.circular(pillHeight),
            ),
            child: icon,
          ),
        ),
      ),
    );
  }
}
