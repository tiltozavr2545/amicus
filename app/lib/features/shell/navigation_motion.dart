import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/glass_selection.dart';

/// Shared by the bar and branch container so a drag moves both in one frame.
class NavigationMotion extends InheritedWidget {
  const NavigationMotion({
    super.key,
    required this.position,
    required this.enabled,
    required this.selectedIndex,
    required this.composer,
    required super.child,
  });

  final AnimationController position;
  final bool enabled;
  final int selectedIndex;
  final Widget? composer;

  static NavigationMotion of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NavigationMotion>()!;

  @override
  bool updateShouldNotify(NavigationMotion oldWidget) =>
      enabled != oldWidget.enabled ||
      position != oldWidget.position ||
      selectedIndex != oldWidget.selectedIndex ||
      composer != oldWidget.composer;
}

/// Mount branches on first display and retain their independent back stacks.
class NavigationPages extends StatefulWidget {
  const NavigationPages({
    super.key,
    required this.shell,
    required this.children,
  });
  final StatefulNavigationShell shell;
  final List<Widget> children;

  @override
  State<NavigationPages> createState() => _NavigationPagesState();
}

class _NavigationPagesState extends State<NavigationPages> {
  final _visited = <int>{};

  @override
  Widget build(BuildContext context) {
    final motion = NavigationMotion.of(context);
    return AnimatedBuilder(
      animation: motion.position,
      builder: (context, _) {
        final position = motion.enabled
            ? motion.position.value
            : motion.selectedIndex.toDouble();
        final direction = Directionality.of(context) == TextDirection.ltr
            ? 1
            : -1;
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (var i = 0; i < widget.children.length + 1; i++)
                _branch(i, position, direction),
            ],
          ),
        );
      },
    );
  }

  Widget _branch(int index, double position, int direction) {
    final motion = NavigationMotion.of(context);
    final visible = (index - position).abs() < 1;
    if (visible || index == motion.selectedIndex) _visited.add(index);
    final page = index == 1
        ? (visible || index == motion.selectedIndex
              ? motion.composer ?? const SizedBox.shrink()
              : const SizedBox.shrink())
        : widget.children[index < 1 ? index : index - 1];
    return Offstage(
      offstage: !visible,
      child: TickerMode(
        enabled: visible,
        child: ExcludeFocus(
          excluding: index != motion.selectedIndex,
          child: IgnorePointer(
            ignoring: index != motion.selectedIndex || position != index,
            child: FractionalTranslation(
              translation: Offset((index - position) * direction, 0),
              child: _visited.contains(index) ? page : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}

/// A glass selection moves with the pages on Amicus's own teal surface.
class AmicusNavigationBar extends StatelessWidget {
  const AmicusNavigationBar({
    super.key,
    required this.position,
    required this.selectedIndex,
    required this.destinations,
    required this.onSelected,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  final AnimationController position;
  final int selectedIndex;
  final List<NavigationDestination> destinations;
  final ValueChanged<int> onSelected;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<double> onDragEnd;
  final VoidCallback onDragCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            color: scheme.surfaceContainerLowest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: .65),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final slot = constraints.maxWidth / destinations.length;
                final indicatorWidth = slot - 10;
                final rtl = Directionality.of(context) == TextDirection.rtl;
                return GestureDetector(
                  key: const ValueKey('amicus-navigation'),
                  onHorizontalDragStart: (_) => onDragStart(),
                  onHorizontalDragUpdate: (details) =>
                      onDragUpdate(details.delta.dx / slot * (rtl ? -1 : 1)),
                  onHorizontalDragEnd: (details) => onDragEnd(
                    (details.primaryVelocity ?? 0) / slot * (rtl ? -1 : 1),
                  ),
                  onHorizontalDragCancel: onDragCancel,
                  child: Stack(
                    children: [
                      AnimatedBuilder(
                        animation: position,
                        builder: (context, _) => PositionedDirectional(
                          start:
                              position.value * slot +
                              (slot - indicatorWidth) / 2,
                          top: 5,
                          bottom: 5,
                          width: indicatorWidth,
                          child: const GlassSelection(radius: 25),
                        ),
                      ),
                      Theme(
                        data: theme.copyWith(
                          splashFactory: NoSplash.splashFactory,
                          highlightColor: Colors.transparent,
                          navigationBarTheme: theme.navigationBarTheme.copyWith(
                            iconTheme: WidgetStateProperty.resolveWith(
                              (states) => IconThemeData(
                                color: states.contains(WidgetState.selected)
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                        child: NavigationBar(
                          animationDuration: Duration.zero,
                          overlayColor: const WidgetStatePropertyAll(
                            Colors.transparent,
                          ),
                          backgroundColor: Colors.transparent,
                          surfaceTintColor: Colors.transparent,
                          indicatorColor: Colors.transparent,
                          elevation: 0,
                          selectedIndex: selectedIndex,
                          onDestinationSelected: onSelected,
                          destinations: destinations,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
