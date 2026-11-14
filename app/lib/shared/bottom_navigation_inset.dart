import 'package:flutter/material.dart';

/// Scrollable tails must clear the complete floating bar, including its safe area.
class BottomNavigationInset extends InheritedWidget {
  const BottomNavigationInset({
    super.key,
    required this.height,
    required super.child,
  });

  final double height;

  static double of(BuildContext context) {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) return 0;
    return context
            .dependOnInheritedWidgetOfExactType<BottomNavigationInset>()
            ?.height ??
        0;
  }

  @override
  bool updateShouldNotify(BottomNavigationInset oldWidget) =>
      height != oldWidget.height;
}
