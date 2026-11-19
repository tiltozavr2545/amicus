import 'package:flutter/material.dart';

/// Keep the photo at its final display size throughout the route transition.
Route<void> photoViewerRoute(WidgetBuilder builder) => PageRouteBuilder<void>(
  pageBuilder: (context, _, _) => builder(context),
  transitionDuration: const Duration(milliseconds: 160),
  reverseTransitionDuration: const Duration(milliseconds: 120),
  transitionsBuilder: (_, animation, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  ),
);
