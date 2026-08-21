import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_providers.dart';
import 'account_repository.dart';
import 'notification_preferences_repository.dart';

final _notificationPreferencesProvider =
    FutureProvider.autoDispose<NotificationPreferences>((ref) {
      final userId = ref.watch(currentUserIdProvider)!;
      return ref.watch(notificationPreferencesRepositoryProvider).fetch(userId);
    });

/// Reads the version/build baked in at build time (`pubspec.yaml`'s
/// `version:`, via the platform's own app metadata) rather than hardcoding
/// it here, so this label can't go stale the way a literal string would.
final _packageInfoProvider = FutureProvider.autoDispose<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
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

  bool _isSigningOut = false;
  bool _isDeletingAccount = false;

  Future<bool> _confirm({
    required String title,
    required String content,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: destructive
                ? TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _signOut() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.signOutDialogTitle,
      content: l10n.signOutDialogContent,
      confirmLabel: l10n.signOutButton,
    );
    if (!confirmed) return;
    if (!mounted) return;

    final userId = ref.read(currentUserIdProvider)!;
    setState(() => _isSigningOut = true);
    try {
      await ref.read(accountRepositoryProvider).signOut(userId);
      // No explicit navigation: the router's redirect reacts to the auth
      // state change this triggers and sends us to /sign-in on its own —
      // same as the sign-out this replaces on ProfileScreen used to do.
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.failedToSignOutError)));
    } finally {
      if (mounted) setState(() => _isSigningOut = false);
    }
  }

  Future<void> _deleteAccount() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await _confirm(
      title: l10n.deleteAccountDialogTitle,
      content: l10n.deleteAccountDialogContent,
      confirmLabel: l10n.deleteButton,
      destructive: true,
    );
    if (!confirmed) return;
    if (!mounted) return;

    final userId = ref.read(currentUserIdProvider)!;
    setState(() => _isDeletingAccount = true);
    try {
      await ref.read(accountRepositoryProvider).deleteAccount(userId);
      // Same as _signOut(): the router picks up the now-cleared session on
      // its own.
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.failedToDeleteAccountError)));
    } finally {
      if (mounted) setState(() => _isDeletingAccount = false);
    }
  }

  /// Flips one switch optimistically and persists the result.
  ///
  /// [set] writes a single field, so a failure can be undone by writing that
  /// same field back on top of *current* state. Restoring a whole snapshot
  /// taken before the request — which is what this did — silently undid any
  /// other switch that had succeeded in the meantime: turn Comments off, then
  /// Digest off before the first request returns, let the first one time out,
  /// and both switches jumped back to on while the server had both off. Since
  /// [NotificationPreferencesRepository.save] upserts all five booleans at
  /// once, the next unrelated toggle then wrote that stale picture back and
  /// quietly re-enabled pushes the user had turned off.
  Future<void> _toggle(
    NotificationPreferences Function(NotificationPreferences, bool) set,
    bool value,
  ) async {
    final current = _prefs;
    if (current == null) return;
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    final next = set(current, value);
    setState(() => _prefs = next);
    try {
      await ref
          .read(notificationPreferencesRepositoryProvider)
          .save(userId, next);
    } catch (_) {
      if (!mounted) return;
      final latest = _prefs;
      if (latest != null) setState(() => _prefs = set(latest, !value));
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
    final packageInfoAsync = ref.watch(_packageInfoProvider);

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
                title: Text(l10n.notifyAppUpdatesLabel),
                value: prefs.systemAccount,
                onChanged: (value) =>
                    _toggle((p, v) => p.copyWith(systemAccount: v), value),
              ),
              SwitchListTile(
                title: Text(l10n.notifyFavoritesLabel),
                value: prefs.favorites,
                onChanged: (value) =>
                    _toggle((p, v) => p.copyWith(favorites: v), value),
              ),
              SwitchListTile(
                title: Text(l10n.notifyCommentsLabel),
                value: prefs.comments,
                onChanged: (value) =>
                    _toggle((p, v) => p.copyWith(comments: v), value),
              ),
              SwitchListTile(
                title: Text(l10n.notifyDigestLabel),
                value: prefs.digest,
                onChanged: (value) =>
                    _toggle((p, v) => p.copyWith(digest: v), value),
              ),
              SwitchListTile(
                title: Text(l10n.notifyInactiveLabel),
                value: prefs.inactiveWeek,
                onChanged: (value) =>
                    _toggle((p, v) => p.copyWith(inactiveWeek: v), value),
              ),
              const Divider(height: 32),
              ListTile(
                title: Text(
                  l10n.languageSectionTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                trailing: DropdownButton<Locale?>(
                  value: ref.watch(localeProvider),
                  underline: const SizedBox.shrink(),
                  onChanged: (value) =>
                      ref.read(localeProvider.notifier).setLocale(value),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(l10n.languageSystemLabel),
                    ),
                    const DropdownMenuItem(
                      value: Locale('en'),
                      child: Text('English'),
                    ),
                    const DropdownMenuItem(
                      value: Locale('ru'),
                      child: Text('Русский'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 32),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(
                  l10n.accountSectionTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ListTile(
                title: Text(l10n.signOutButton),
                trailing: _isSigningOut
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: _isSigningOut ? null : _signOut,
              ),
              ListTile(
                title: Text(
                  l10n.deleteAccountLabel,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                trailing: _isDeletingAccount
                    ? SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      )
                    : null,
                onTap: _isDeletingAccount ? null : _deleteAccount,
              ),
              if (packageInfoAsync.hasValue) ...[
                const Divider(height: 32),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Text(
                    l10n.appVersionLabel(
                      packageInfoAsync.value!.version,
                      packageInfoAsync.value!.buildNumber,
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
