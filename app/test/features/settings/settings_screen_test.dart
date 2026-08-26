import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/settings/account_repository.dart';
import 'package:amicus/features/settings/notification_preferences_repository.dart';
import 'package:amicus/features/settings/settings_screen.dart';
import 'package:amicus/l10n/app_localizations.dart';

class _FakeNotificationPreferencesRepository
    implements NotificationPreferencesRepository {
  NotificationPreferences stored = const NotificationPreferences();
  bool saveThrows = false;
  int saveCalls = 0;
  NotificationPreferences? lastSaved;

  /// When true, every [save] parks on a fresh completer appended to [gates],
  /// so a test can hold several writes in flight at once and settle them out
  /// of order. Complete a gate to let that call succeed, or `completeError` it
  /// to fail just that one.
  bool gateSaves = false;
  final List<Completer<void>> gates = [];

  @override
  Future<NotificationPreferences> fetch(String userId) async => stored;

  @override
  Future<void> save(String userId, NotificationPreferences prefs) async {
    saveCalls++;
    lastSaved = prefs;
    if (gateSaves) {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    }
    if (saveThrows) throw Exception('network error');
    stored = prefs;
  }
}

class _FakeAccountRepository implements AccountRepository {
  bool signOutThrows = false;
  bool deleteAccountThrows = false;
  int signOutCalls = 0;
  int deleteAccountCalls = 0;
  String? lastUserId;

  @override
  Future<void> signOut(String userId) async {
    signOutCalls++;
    lastUserId = userId;
    if (signOutThrows) throw Exception('network error');
  }

  @override
  Future<void> deleteAccount(String userId) async {
    deleteAccountCalls++;
    lastUserId = userId;
    if (deleteAccountThrows) throw Exception('network error');
  }
}

Widget _wrap(
  _FakeNotificationPreferencesRepository repo, {
  _FakeAccountRepository? accountRepo,
}) {
  return ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('test-user'),
      notificationPreferencesRepositoryProvider.overrideWithValue(repo),
      accountRepositoryProvider.overrideWithValue(
        accountRepo ?? _FakeAccountRepository(),
      ),
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
    expect(switches, hasLength(7));
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

  testWidgets('Sign out asks for confirmation; cancelling does nothing', (
    tester,
  ) async {
    final accountRepo = _FakeAccountRepository();
    await tester.pumpWidget(
      _wrap(_FakeNotificationPreferencesRepository(), accountRepo: accountRepo),
    );
    await tester.pump();

    await tester.scrollUntilVisible(find.text('Sign out'), 200);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(accountRepo.signOutCalls, 0);
  });

  testWidgets('Confirming sign out calls the repository with the user id', (
    tester,
  ) async {
    final accountRepo = _FakeAccountRepository();
    await tester.pumpWidget(
      _wrap(_FakeNotificationPreferencesRepository(), accountRepo: accountRepo),
    );
    await tester.pump();

    await tester.scrollUntilVisible(find.text('Sign out'), 200);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    // Two matches now: the list tile behind the dialog and the dialog's own
    // confirm button, both labelled "Sign out" — the confirm action is the
    // last one.
    await tester.tap(find.text('Sign out').last);
    await tester.pumpAndSettle();

    expect(accountRepo.signOutCalls, 1);
    expect(accountRepo.lastUserId, 'test-user');
  });

  testWidgets('A failed sign out shows a snackbar', (tester) async {
    final accountRepo = _FakeAccountRepository()..signOutThrows = true;
    await tester.pumpWidget(
      _wrap(_FakeNotificationPreferencesRepository(), accountRepo: accountRepo),
    );
    await tester.pump();

    await tester.scrollUntilVisible(find.text('Sign out'), 200);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out').last);
    await tester.pumpAndSettle();

    expect(find.text('Failed to sign out. Please try again.'), findsOneWidget);
  });

  testWidgets(
    'Confirming delete account calls the repository with the user id',
    (tester) async {
      final accountRepo = _FakeAccountRepository();
      await tester.pumpWidget(
        _wrap(
          _FakeNotificationPreferencesRepository(),
          accountRepo: accountRepo,
        ),
      );
      await tester.pump();

      await tester.scrollUntilVisible(find.text('Delete account'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      expect(find.text('Delete account?'), findsOneWidget);

      // The dialog's confirm button reuses the generic "Delete" label, not
      // "Delete account" — only one match, unlike the sign-out case above.
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(accountRepo.deleteAccountCalls, 1);
      expect(accountRepo.lastUserId, 'test-user');
    },
  );

  testWidgets('Cancelling delete account does nothing', (tester) async {
    final accountRepo = _FakeAccountRepository();
    await tester.pumpWidget(
      _wrap(_FakeNotificationPreferencesRepository(), accountRepo: accountRepo),
    );
    await tester.pump();

    await tester.scrollUntilVisible(find.text('Delete account'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(accountRepo.deleteAccountCalls, 0);
  });

  testWidgets('A failed account deletion shows a snackbar', (tester) async {
    final accountRepo = _FakeAccountRepository()..deleteAccountThrows = true;
    await tester.pumpWidget(
      _wrap(_FakeNotificationPreferencesRepository(), accountRepo: accountRepo),
    );
    await tester.pump();

    await tester.scrollUntilVisible(find.text('Delete account'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
      find.text('Failed to delete account. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'A failed toggle rolls back only its own field, not a concurrent one',
    (tester) async {
      // Regression: the rollback used to restore the whole snapshot taken
      // before the request, so a failing toggle silently undid a different
      // toggle that had already succeeded — and because save() upserts all
      // five booleans, the next write persisted that stale picture.
      final repo = _FakeNotificationPreferencesRepository()..gateSaves = true;
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      const commentsLabel = 'Comments on your posts and replies to you';
      const digestLabel = 'Digest of posts from everyone else';

      await tester.tap(find.text(commentsLabel));
      await tester.pump();
      await tester.tap(find.text(digestLabel));
      await tester.pump();
      expect(repo.saveCalls, 2);
      expect(repo.gates, hasLength(2));

      // The second write lands; the first one then fails.
      repo.gates[1].complete();
      await tester.pump();
      repo.gates[0].completeError(Exception('network error'));
      await tester.pump();

      SwitchListTile tileFor(String label) => tester.widget<SwitchListTile>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(SwitchListTile),
        ),
      );

      // Only the failed field comes back on.
      expect(tileFor(commentsLabel).value, true);
      // The one that succeeded stays off.
      expect(tileFor(digestLabel).value, false);
    },
  );
}
