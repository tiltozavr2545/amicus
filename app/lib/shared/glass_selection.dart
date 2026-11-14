import 'package:flutter/material.dart';

/// Shared glass rim and tint over the opaque navigation/search surfaces.
/// A backdrop blur would only resample that solid surface on every repaint.
class GlassSelection extends StatelessWidget {
  const GlassSelection({super.key, required this.radius});
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: scheme.onSurface.withValues(alpha: 0.14)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.secondaryContainer.withValues(alpha: 0.85),
              scheme.primary.withValues(alpha: 0.12),
            ],
          ),
        ),
      ),
    );
  }
}
