import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';

/// Opens [SettingsScreen]. Shown in the top bar's actions, next to
/// [ThemeToggleSwitch] on every main tab.
class SettingsButton extends StatelessWidget {
  const SettingsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IconButton(
      icon: const Icon(Icons.settings),
      tooltip: l10n.settingsTooltip,
      onPressed: () => context.push('/settings'),
    );
  }
}
