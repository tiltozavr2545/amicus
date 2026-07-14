import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import 'theme_mode_provider.dart';

/// Light/dark toggle shown in the top bar's actions, opposite the title.
class ThemeToggleSwitch extends ConsumerWidget {
  const ThemeToggleSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final systemIsDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final isDark =
        themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system && systemIsDark);
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: l10n.darkThemeToggleTooltip,
      child: Switch(
        value: isDark,
        onChanged: (_) =>
            ref.read(themeModeProvider.notifier).toggle(systemIsDark),
        thumbIcon: WidgetStateProperty.resolveWith<Icon?>(
          (states) => Icon(
            states.contains(WidgetState.selected)
                ? Icons.dark_mode
                : Icons.light_mode,
            size: 16,
          ),
        ),
      ),
    );
  }
}
