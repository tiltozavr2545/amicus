import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/connections/friend_profile_screen.dart';
import '../features/profile/profile_repository.dart';
import '../l10n/app_localizations.dart';
import '../shared/system_account_id.dart';
import '../shared/tap_streak.dart';
import 'theme_mode_provider.dart';

/// Counts flips of the switch below. A plain [Provider] rather than state on
/// the widget: this sits in the top bar and is rebuilt on every frame that
/// touches the theme, so a field would reset constantly.
final _toggleStreakProvider = Provider<TapStreak>((ref) => TapStreak(6));

/// Light/dark toggle shown in the top bar's actions, opposite the title.
class ThemeToggleSwitch extends ConsumerWidget {
  const ThemeToggleSwitch({super.key});

  Future<void> _openSystemAccountProfile(
    BuildContext context,
    WidgetRef ref,
  ) async {
    // Swallowed on purpose: this is a side path off a switch whose actual job
    // (flipping the theme) has already succeeded, and it has no error surface
    // of its own. Without the guard a flaky connection turned an unhandled
    // `fetchProfile` throw loose from a top-bar widget.
    final Profile profile;
    try {
      profile = await ref
          .read(profileRepositoryProvider)
          .fetchProfile(systemAccountId);
    } catch (_) {
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FriendProfileScreen(
          friendId: profile.id,
          friendName: profile.name,
          avatarPath: profile.avatarPath,
        ),
      ),
    );
  }

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
        onChanged: (_) async {
          await ref.read(themeModeProvider.notifier).toggle(systemIsDark);
          if (!ref.read(_toggleStreakProvider).record()) return;
          if (!context.mounted) return;
          await _openSystemAccountProfile(context, ref);
        },
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
