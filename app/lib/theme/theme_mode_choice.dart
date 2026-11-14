import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/connections/friend_profile_screen.dart';
import '../features/profile/profile_repository.dart';
import '../l10n/app_localizations.dart';
import '../shared/system_accounts.dart';
import '../shared/tap_streak.dart';
import 'theme_mode_provider.dart';

/// Preserve the six-change shortcut when choosing appearance in Settings.
final _toggleStreakProvider = Provider<TapStreak>((ref) => TapStreak(6));

class ThemeModeChoice extends ConsumerWidget {
  const ThemeModeChoice({super.key});

  Future<void> _openSystemAccountProfile(
    BuildContext context,
    WidgetRef ref,
  ) async {
    // A failed shortcut must not affect the already saved theme preference.
    final accounts = ref.read(systemAccountsProvider);
    final repository = ref.read(profileRepositoryProvider);
    final Profile profile;
    try {
      final ids = await accounts.ids();
      if (ids.isEmpty) return;
      profile = await repository.fetchProfile(ids.first);
    } catch (_) {
      return;
    }
    if (!context.mounted) return;
    // `unawaited`, not `await`: the Future from `push()` completes when the
    // opened screen is LEFT, not when it opens. There is nothing to do here
    // after the navigation, so there is nothing to wait for and no reason to —
    // and the word says the Future is dropped on purpose.
    unawaited(
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => FriendProfileScreen(
            friendId: profile.id,
            friendName: profile.name,
            avatarPath: profile.avatarPath,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return DropdownButton<ThemeMode>(
      isExpanded: true,
      style: Theme.of(context).textTheme.bodyLarge,
      itemHeight: null,
      value: ref.watch(themeModeProvider),
      underline: const SizedBox.shrink(),
      onChanged: (mode) async {
        if (mode == null || mode == ref.read(themeModeProvider)) return;
        final notifier = ref.read(themeModeProvider.notifier);
        final streak = ref.read(_toggleStreakProvider);
        try {
          await notifier.setMode(mode);
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.failedToSaveSettingsError)),
            );
          }
          return;
        }
        if (!context.mounted || !streak.record()) return;
        await _openSystemAccountProfile(context, ref);
      },
      items: [
        DropdownMenuItem(
          value: ThemeMode.system,
          child: Text(l10n.languageSystemLabel),
        ),
        DropdownMenuItem(
          value: ThemeMode.light,
          child: Text(l10n.themeLightLabel),
        ),
        DropdownMenuItem(
          value: ThemeMode.dark,
          child: Text(l10n.themeDarkLabel),
        ),
      ],
    );
  }
}
