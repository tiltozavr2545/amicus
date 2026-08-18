import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../auth/auth_providers.dart';
import 'notification_preferences_repository.dart';

final _notificationPreferencesProvider =
    FutureProvider.autoDispose<NotificationPreferences>((ref) {
      final userId = ref.watch(currentUserIdProvider)!;
      return ref.watch(notificationPreferencesRepositoryProvider).fetch(userId);
    });

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Seeded once from the fetched row (see build()), then owned locally so a
  // toggle can apply optimistically without waiting on a refetch — same
  // seed-once-from-async-data shape as ProfileScreen's `_nameController`.
  NotificationPreferences? _prefs;

  Future<void> _toggle(
    NotificationPreferences Function(NotificationPreferences) apply,
  ) async {
    final previous = _prefs;
    if (previous == null) return;
    final userId = ref.read(currentUserIdProvider)!;
    final next = apply(previous);
    setState(() => _prefs = next);
    try {
      await ref
          .read(notificationPreferencesRepositoryProvider)
          .save(userId, next);
    } catch (_) {
      if (!mounted) return;
      setState(() => _prefs = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.failedToSaveSettingsError,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final prefsAsync = ref.watch(_notificationPreferencesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: prefsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) =>
            Center(child: Text(l10n.failedToLoadSettingsError)),
        data: (loaded) {
          _prefs ??= loaded;
          final prefs = _prefs!;
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  l10n.notificationsSectionTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              SwitchListTile(
                title: Text(l10n.notifyAmicusLabel),
                value: prefs.systemAccount,
                onChanged: (value) =>
                    _toggle((p) => p.copyWith(systemAccount: value)),
              ),
              SwitchListTile(
                title: Text(l10n.notifyFavoritesLabel),
                value: prefs.favorites,
                onChanged: (value) =>
                    _toggle((p) => p.copyWith(favorites: value)),
              ),
              SwitchListTile(
                title: Text(l10n.notifyCommentsLabel),
                value: prefs.comments,
                onChanged: (value) =>
                    _toggle((p) => p.copyWith(comments: value)),
              ),
              SwitchListTile(
                title: Text(l10n.notifyDigestLabel),
                value: prefs.digest,
                onChanged: (value) => _toggle((p) => p.copyWith(digest: value)),
              ),
              SwitchListTile(
                title: Text(l10n.notifyInactiveLabel),
                value: prefs.inactiveWeek,
                onChanged: (value) =>
                    _toggle((p) => p.copyWith(inactiveWeek: value)),
              ),
            ],
          );
        },
      ),
    );
  }
}
