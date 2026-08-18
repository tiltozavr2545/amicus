import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/settings/notification_preferences_repository.dart';
import 'package:amicus/features/settings/settings_screen.dart';
import 'package:amicus/l10n/app_localizations.dart';

class _FakeNotificationPreferencesRepository
    implements NotificationPreferencesRepository {
  NotificationPreferences stored = const NotificationPreferences();
  bool saveThrows = false;
  int saveCalls = 0;
  NotificationPreferences? lastSaved;

  @override
  Future<NotificationPreferences> fetch(String userId) async => stored;

  @override
  Future<void> save(String userId, NotificationPreferences prefs) async {
    saveCalls++;
    lastSaved = prefs;
    if (saveThrows) throw Exception('network error');
    stored = prefs;
  }
}

Widget _wrap(_FakeNotificationPreferencesRepository repo) {
  return ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('test-user'),
      notificationPreferencesRepositoryProvider.overrideWithValue(repo),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsScreen(),
    ),
  );
}

void main() {
  testWidgets('Every toggle starts on by default', (tester) async {
    final repo = _FakeNotificationPreferencesRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    final switches = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(switches, hasLength(5));
    expect(switches.every((s) => s.value), true);
  });

  testWidgets('Turning a toggle off saves it and keeps it off', (tester) async {
    final repo = _FakeNotificationPreferencesRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.tap(find.text('Comments on your posts and replies to you'));
    await tester.pump();

    expect(repo.saveCalls, 1);
    expect(repo.lastSaved!.comments, false);
    // Every other preference is untouched by this one toggle.
    expect(repo.lastSaved!.systemAccount, true);
    expect(repo.lastSaved!.favorites, true);
    expect(repo.lastSaved!.digest, true);
    expect(repo.lastSaved!.inactiveWeek, true);

    final tile = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('Comments on your posts and replies to you'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(tile.value, false);
  });

  testWidgets('A failed save rolls the toggle back and shows a snackbar', (
    tester,
  ) async {
    final repo = _FakeNotificationPreferencesRepository()..saveThrows = true;
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.tap(find.text('Digest of posts from everyone else'));
    await tester.pump();

    final tile = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('Digest of posts from everyone else'),
        matching: find.byType(SwitchListTile),
      ),
    );
    // Rolled back to on, despite the optimistic flip to off.
    expect(tile.value, true);
    expect(find.text('Failed to save. Please try again.'), findsOneWidget);
  });
}
