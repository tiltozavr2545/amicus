import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/locale_provider.dart';
import '../../shared/content_width.dart';
import '../../theme/theme_mode_choice.dart';
import '../../theme/navigation_style_provider.dart';
import 'settings_choice.dart';
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
  NotificationPreferences? _prefs;
  final _pending = <NotificationPreference, bool>{};
  final _saved = <NotificationPreference, bool>{};
  bool _serverLoaded = false;
  Future<void> _cacheWrite = Future.value();

  @override
  void initState() {
    super.initState();
    final userId = ref.read(currentUserIdProvider);
    unawaited(_loadCached(userId));
  }

  Future<void> _loadCached(String? userId) async {
    try {
      final store = await SharedPreferences.getInstance();
      final raw = store.getString('notification_preferences_$userId');
      if (raw == null || !mounted || _serverLoaded) return;
      final value = NotificationPreferences.fromRow(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      setState(() => _prefs = value);
      if (_saved.isNotEmpty) _remember();
    } catch (_) {}
  }

  NotificationPreferences _withChanges(
    NotificationPreferences prefs,
    Map<NotificationPreference, bool> changes,
  ) {
    for (final MapEntry(key: preference, value: enabled) in changes.entries) {
      prefs = preference.applyTo(prefs, enabled);
    }
    return prefs;
  }

  void _remember() {
    final base = _prefs;
    if (base == null) return;
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    final value = _withChanges(base, _saved);
    _cacheWrite = _cacheWrite
        .then((_) async {
          final store = await SharedPreferences.getInstance();
          await store.setString(
            'notification_preferences_$userId',
            jsonEncode({
              'notify_system_account': value.systemAccount,
              'notify_favorites': value.favorites,
              'notify_comments': value.comments,
              'notify_digest': value.digest,
              'notify_inactive_week': value.inactiveWeek,
              'notify_room_messages': value.roomMessages,
            }),
          );
        })
        .catchError((Object _) {});
  }

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

  Future<void> _toggle(NotificationPreference preference, bool value) async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null || _pending.containsKey(preference)) return;
    setState(() => _pending[preference] = value);
    try {
      await ref
          .read(notificationPreferencesRepositoryProvider)
          .save(userId, preference, value);
      if (!mounted) return;
      _saved[preference] = value;
      _remember();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.failedToSaveSettingsError,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _pending.remove(preference));
    }
  }

  ValueChanged<bool>? _onToggle(NotificationPreference preference) =>
      _pending.containsKey(preference)
      ? null
      : (value) => _toggle(preference, value);

  Future<void> _savePreference(Future<void> Function() save) async {
    try {
      await save();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.failedToSaveSettingsError,
          ),
        ),
      );
    }
  }

  Widget _group(List<Widget> children) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );

  Widget _section(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
    child: Text(
      label,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final prefsAsync = ref.watch(_notificationPreferencesProvider);
    ref.listen(_notificationPreferencesProvider, (_, next) {
      final loaded = next.asData?.value;
      if (loaded == null) return;
      _serverLoaded = true;
      _prefs = loaded;
      _remember();
    });
    final packageInfoAsync = ref.watch(_packageInfoProvider);
    final busy = _isSigningOut || _isDeletingAccount;
    final dropdownStyle = Theme.of(context).textTheme.bodyLarge;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _section(l10n.notificationsSectionTitle),
            _group([
              Builder(
                builder: (context) {
                  final base =
                      _prefs ??
                      prefsAsync.asData?.value ??
                      const NotificationPreferences();
                  final prefs = _withChanges(
                    _withChanges(base, _saved),
                    _pending,
                  );
                  return Column(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.campaign_outlined),
                        title: Text(l10n.notifyAppUpdatesLabel),
                        value: prefs.systemAccount,
                        onChanged: _onToggle(
                          NotificationPreference.systemAccount,
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.star_outline),
                        title: Text(l10n.notifyFavoritesLabel),
                        value: prefs.favorites,
                        onChanged: _onToggle(NotificationPreference.favorites),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.chat_bubble_outline),
                        title: Text(l10n.notifyCommentsLabel),
                        value: prefs.comments,
                        onChanged: _onToggle(NotificationPreference.comments),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.view_agenda_outlined),
                        title: Text(l10n.notifyDigestLabel),
                        value: prefs.digest,
                        onChanged: _onToggle(NotificationPreference.digest),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.schedule_outlined),
                        title: Text(l10n.notifyInactiveLabel),
                        value: prefs.inactiveWeek,
                        onChanged: _onToggle(
                          NotificationPreference.inactiveWeek,
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.forum_outlined),
                        title: Text(l10n.notifyRoomMessagesLabel),
                        value: prefs.roomMessages,
                        onChanged: _onToggle(
                          NotificationPreference.roomMessages,
                        ),
                      ),
                    ],
                  );
                },
              ),
              if (prefsAsync.hasError)
                ListTile(
                  title: Text(l10n.failedToLoadSettingsError),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () =>
                        ref.invalidate(_notificationPreferencesProvider),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            _section(l10n.appearanceSectionTitle),
            _group([
              SettingsChoice(
                icon: Icons.view_day_outlined,
                title: l10n.navigationStyleLabel,
                selection: DropdownButton<bool>(
                  isExpanded: true,
                  itemHeight: null,
                  style: dropdownStyle,
                  value: ref.watch(floatingNavigationProvider),
                  underline: const SizedBox.shrink(),
                  onChanged: (floating) {
                    if (floating != null) {
                      final notifier = ref.read(
                        floatingNavigationProvider.notifier,
                      );
                      _savePreference(() => notifier.setFloating(floating));
                    }
                  },
                  items: [
                    DropdownMenuItem(
                      value: true,
                      child: Text(l10n.navigationFloatingLabel),
                    ),
                    DropdownMenuItem(
                      value: false,
                      child: Text(l10n.navigationClassicLabel),
                    ),
                  ],
                ),
              ),
              SettingsChoice(
                icon: Icons.language,
                title: l10n.languageSectionTitle,
                selection: DropdownButton<String>(
                  isExpanded: true,
                  itemHeight: null,
                  style: dropdownStyle,
                  value: ref.watch(localeProvider)?.languageCode ?? '',
                  underline: const SizedBox.shrink(),
                  onChanged: (code) {
                    if (code == null) return;
                    final notifier = ref.read(localeProvider.notifier);
                    _savePreference(
                      () => notifier.setLocale(
                        code.isEmpty ? null : Locale(code),
                      ),
                    );
                  },
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(l10n.languageSystemLabel),
                    ),
                    const DropdownMenuItem(value: 'en', child: Text('English')),
                    const DropdownMenuItem(value: 'ru', child: Text('Русский')),
                  ],
                ),
              ),
              SettingsChoice(
                icon: Icons.brightness_6_outlined,
                title: l10n.themeLabel,
                selection: const ThemeModeChoice(),
              ),
            ]),
            const SizedBox(height: 8),
            _section(l10n.accountSectionTitle),
            _group([
              ListTile(
                leading: const Icon(Icons.logout),
                title: Text(l10n.signOutButton),
                trailing: _isSigningOut
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: busy ? null : _signOut,
              ),
              ListTile(
                leading: Icon(
                  Icons.person_remove_outlined,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  l10n.deleteAccountLabel,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                trailing: _isDeletingAccount
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: busy ? null : _deleteAccount,
              ),
            ]),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.aboutTitle),
              subtitle: packageInfoAsync.value == null
                  ? null
                  : Text(
                      l10n.appVersionLabel(
                        packageInfoAsync.value!.version,
                        packageInfoAsync.value!.buildNumber,
                      ),
                    ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showAboutDialog(
                context: context,
                applicationName: 'Amicus',
                applicationVersion: packageInfoAsync.value?.version,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
