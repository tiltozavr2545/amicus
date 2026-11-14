import 'package:flutter/material.dart';

/// Framebook's settings arrangement: a row that stacks at narrow widths.
class SettingsChoice extends StatelessWidget {
  const SettingsChoice({
    super.key,
    required this.icon,
    required this.title,
    required this.selection,
  });

  final IconData icon;
  final String title;
  final Widget selection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.titleMedium!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stacked =
                    constraints.maxWidth < 260 ||
                    MediaQuery.textScalerOf(context).scale(style.fontSize!) >
                        style.fontSize! * 1.3;
                final label = Text(title, style: style);
                final choice = selection;
                return stacked
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [label, choice],
                      )
                    : Row(
                        children: [
                          Expanded(child: label),
                          const SizedBox(width: 16),
                          Expanded(child: choice),
                        ],
                      );
              },
            ),
          ),
        ],
      ),
    );
  }
}
