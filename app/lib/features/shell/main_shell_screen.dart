import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/navigation_style_provider.dart';
import '../../shared/bottom_navigation_inset.dart';
import 'navigation_motion.dart';
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
/// correspond to a shell branch: the motion container displays the composer
/// in a temporary slot; its draft is persisted separately by the composer.
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

class _MainShellScreenState extends ConsumerState<MainShellScreen>
    with SingleTickerProviderStateMixin {
  late final _position = AnimationController.unbounded(
    vsync: this,
    value: MainShellScreen._destinationIndexForBranch(
      widget.navigationShell.currentIndex,
    ).toDouble(),
  );
  late int _routeIndex = _selectedIndex(widget.navigationShell);
  bool _dragging = false;
  int _dragOrigin = 0;

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  void _settle(int index, {bool reset = false}) {
    _dragging = false;
    _routeIndex = index;
    if (MediaQuery.disableAnimationsOf(context)) {
      _position.value = index.toDouble();
    } else {
      _position.animateTo(
        index.toDouble(),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
    _onDestinationSelected(index, widget.navigationShell, reset: reset);
  }

  void _select(int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    _settle(index, reset: true);
  }

  void _startDrag() {
    FocusManager.instance.primaryFocus?.unfocus();
    _position.stop();
    _dragOrigin = _selectedIndex(widget.navigationShell);
    _dragging = true;
  }

  void _startPageDrag() {
    final shell = widget.navigationShell;
    final navigator =
        shell.route.branches[shell.currentIndex].navigatorKey.currentState;
    if (!_composing && (navigator?.canPop() ?? false)) return;
    _startDrag();
  }

  void _updateDrag(double delta) {
    if (!_dragging) return;
    _position.value = (_position.value + delta).clamp(0.0, 4.0);
    final index = _position.value.round();
    if (index != _selectedIndex(widget.navigationShell)) {
      _routeIndex = index;
      _onDestinationSelected(index, widget.navigationShell, reset: false);
    }
  }

  void _endDrag(double velocity) {
    if (!_dragging) return;
    _settle(
      (_position.value + (velocity.abs() > 2 ? velocity.sign * .35 : 0))
          .round()
          .clamp(0, 4),
    );
  }

  void _cancelDrag() {
    if (_dragging) _settle(_dragOrigin);
  }

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
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
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
    ref.listen(pushRegistrationProvider, (_, _) {});
    // Same fire-and-forget shape, right above: tells the server "the app was
    // just opened" so the digest push can count only posts that appeared
    // since — see notification_preferences' notify_digest and migration
    // 20260819190000.
    ref.listen(userActivityProvider, (_, _) {});
    // Taps on notifications, cold start included. `listen` rather than
    // `watch`: this is an event to act on once, not state to paint.
    ref.listen(pushTapsProvider, (previous, next) {
      if (next.value case final target?) _openPushTarget(target);
    });
    final selected = _selectedIndex(navigationShell);
    if (!_dragging && _routeIndex != selected) {
      _routeIndex = selected;
      _position.value = selected.toDouble();
    }
    final floating = ref.watch(floatingNavigationProvider);
    final barInset = floating
        ? (NavigationBarTheme.of(context).height ?? 68) +
              8 +
              MediaQuery.paddingOf(context).bottom.clamp(12.0, double.infinity)
        : 0.0;
    return Scaffold(
      extendBody: floating,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final direction = Directionality.of(context) == TextDirection.rtl
              ? 1.0
              : -1.0;
          return GestureDetector(
            key: const ValueKey('tab-page-swipe'),
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => _startPageDrag(),
            onHorizontalDragUpdate: (details) => _updateDrag(
              details.delta.dx / constraints.maxWidth * direction,
            ),
            onHorizontalDragEnd: (details) => _endDrag(
              (details.primaryVelocity ?? 0) / constraints.maxWidth * direction,
            ),
            onHorizontalDragCancel: _cancelDrag,
            child: BottomNavigationInset(
              height: barInset,
              child: NavigationMotion(
                position: _position,
                selectedIndex: selected,
                enabled: true,
                composer: PopScope(
                  canPop: !_composing,
                  onPopInvokedWithResult: (didPop, result) {
                    if (!didPop && _composing) _closeCompose(false);
                  },
                  child: CreatePostScreen(onClose: _closeCompose),
                ),
                child: navigationShell,
              ),
            ),
          );
        },
      ),
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
    StatefulNavigationShell navigationShell, {
    bool reset = true,
  }) {
    if (index == _addPostDestinationIndex) {
      setState(() => _composing = true);
      return;
    }
    // The composer flushes its local draft when this transition disposes it.
    if (_composing) setState(() => _composing = false);
    final branchIndex = index < _addPostDestinationIndex ? index : index - 1;
    navigationShell.goBranch(
      branchIndex,
      initialLocation: reset && branchIndex == navigationShell.currentIndex,
    );
  }

  /// Labels and icons are shared by both navigation presentations.
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

  Widget _bottomNavigationBar(
    AppLocalizations l10n,
    StatefulNavigationShell navigationShell,
  ) {
    if (ref.watch(floatingNavigationProvider)) {
      return AmicusNavigationBar(
        position: _position,
        selectedIndex: _selectedIndex(navigationShell),
        destinations: [
          for (final destination in _destinations(l10n))
            NavigationDestination(
              icon: destination.iconBuilder?.call(25) ?? Icon(destination.icon),
              selectedIcon:
                  destination.iconBuilder?.call(25) ??
                  Icon(destination.selectedIcon ?? destination.icon),
              label: destination.label,
            ),
        ],
        onSelected: _select,
        onDragStart: _startDrag,
        onDragUpdate: _updateDrag,
        onDragEnd: _endDrag,
        onDragCancel: _cancelDrag,
      );
    }
    return _BottomBar(
      selectedIndex: _selectedIndex(navigationShell),
      onDestinationSelected: _select,
      destinations: _destinations(l10n),
      floating: ref.watch(floatingNavigationProvider),
    );
  }
}

/// A tab with a standard icon or the current user's avatar.
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

/// Both styles reserve their own space: content is never hidden under the bar.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.floating,
  });

  final List<_BottomBarDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    return SafeArea(
      top: false,
      child: Padding(
        padding: floating
            ? const EdgeInsets.fromLTRB(16, 8, 16, 12)
            : EdgeInsets.zero,
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: floating ? 560 : double.infinity,
            ),
            child: Material(
              color: scheme.surfaceContainerLowest,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(floating ? 24 : 0),
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: .65),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    for (final (index, destination) in destinations.indexed)
                      Expanded(
                        child: _BottomBarIcon(
                          destination: destination,
                          selected: index == selectedIndex,
                          compose: index == _addPostDestinationIndex,
                          iconSize: isTablet ? 30 : 25,
                          onTap: () => onDestinationSelected(index),
                        ),
                      ),
                  ],
                ),
              ),
            ),
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
    required this.compose,
    required this.iconSize,
    required this.onTap,
  });

  final _BottomBarDestination destination;
  final bool selected;
  final bool compose;
  final double iconSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = compose
        ? scheme.onPrimary
        : selected
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final icon =
        destination.iconBuilder?.call(iconSize) ??
        Icon(
          compose
              ? Icons.add
              : selected
              ? (destination.selectedIcon ?? destination.icon)
              : destination.icon,
          size: iconSize,
          color: color,
        );
    return Tooltip(
      message: destination.label,
      child: Semantics(
        button: true,
        selected: selected,
        label: destination.label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 48,
            child: Center(
              child: Container(
                width: 48,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: compose
                      ? scheme.primary
                      : selected
                      ? scheme.surfaceContainerHigh
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(compose ? 16 : 14),
                ),
                child: ExcludeSemantics(child: icon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
