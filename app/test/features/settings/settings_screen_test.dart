import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:amicus/theme/theme_mode_provider.dart';
import 'package:amicus/theme/navigation_style_provider.dart';
import 'package:amicus/theme/amicus_theme.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/settings/account_repository.dart';
import 'package:amicus/features/settings/notification_preferences_repository.dart';
import 'package:amicus/features/settings/settings_screen.dart';
import 'package:amicus/l10n/app_localizations.dart';

class _FakeNotificationPreferencesRepository
    implements NotificationPreferencesRepository {
  NotificationPreferences stored = const NotificationPreferences();
  Completer<NotificationPreferences>? fetchGate;
  bool fetchThrows = false;
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
  Future<NotificationPreferences> fetch(String userId) async {
    if (fetchThrows) throw Exception('offline');
    return fetchGate == null ? stored : await fetchGate!.future;
  }

  @override
  Future<void> save(
    String userId,
    NotificationPreference preference,
    bool enabled,
  ) async {
    saveCalls++;
    if (gateSaves) {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    }
    if (saveThrows) throw Exception('network error');
    stored = preference.applyTo(stored, enabled);
    lastSaved = stored;
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
  Locale locale = const Locale('en'),
}) {
  return ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('test-user'),
      notificationPreferencesRepositoryProvider.overrideWithValue(repo),
      accountRepositoryProvider.overrideWithValue(
        accountRepo ?? _FakeAccountRepository(),
      ),
    ],
    child: MaterialApp(
      theme: AmicusTheme.light,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const SettingsScreen(),
    ),
  );
}

/// Scrolls the settings list to [label] and taps it.
///
/// `scrollUntilVisible` alone is not enough, and the way it fails is quiet:
/// it stops as soon as the finder MATCHES, while a ListView builds a little
/// past its own viewport — so the row can be found while still sitting below
/// the fold, and the tap then lands outside the screen and does nothing.
/// Dropping a single switch from this screen was enough to move a row into
/// that gap. `ensureVisible` closes it, and the pump after it is not optional
/// either: it only schedules the scroll, so without one the tap still uses
/// the pre-scroll position.
Future<void> _scrollToAndTap(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.scrollUntilVisible(finder, 200);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'Theme has system, light and dark choices and persists a return to system',
    (tester) async {
      await tester.pumpWidget(_wrap(_FakeNotificationPreferencesRepository()));
      await tester.pumpAndSettle();
      final choice = find.byType(DropdownButton<ThemeMode>);
      await tester.scrollUntilVisible(choice, 200);
      await tester.scrollUntilVisible(choice, 200);
      await tester.ensureVisible(choice);
      await tester.pumpAndSettle();
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark').last);
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(choice));
      expect(container.read(themeModeProvider), ThemeMode.dark);
      expect(
        (await SharedPreferences.getInstance()).getString('theme_mode'),
        'dark',
      );

      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.text('System default').last);
      await tester.pumpAndSettle();
      expect(container.read(themeModeProvider), ThemeMode.system);
      expect(
        (await SharedPreferences.getInstance()).getString('theme_mode'),
        'system',
      );
    },
  );

  testWidgets(
    'Appearance and account remain available when notification loading fails',
    (tester) async {
      await tester.pumpWidget(
        _wrap(_FakeNotificationPreferencesRepository()..fetchThrows = true),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Failed to load settings. Please try again.'),
        findsOneWidget,
      );
      final choice = find.byType(DropdownButton<ThemeMode>);
      await tester.scrollUntilVisible(choice, 200);
      await tester.ensureVisible(choice);
      await tester.pumpAndSettle();
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light').last);
      await tester.pumpAndSettle();
      expect(
        ProviderScope.containerOf(
          tester.element(choice),
        ).read(themeModeProvider),
        ThemeMode.light,
      );
      await _scrollToAndTap(tester, 'Sign out');
      expect(find.text('Sign out?'), findsOneWidget);
    },
  );

  testWidgets(
    'Russian settings fit a narrow screen and save classic navigation',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _wrap(
          _FakeNotificationPreferencesRepository(),
          locale: const Locale('ru'),
        ),
      );
      await tester.pumpAndSettle();
      final choice = find.byType(DropdownButton<bool>);
      await tester.scrollUntilVisible(choice, 200);
      await tester.scrollUntilVisible(choice, 200);
      await tester.ensureVisible(choice);
      await tester.pumpAndSettle();
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Классическая').last);
      await tester.pumpAndSettle();
      expect(
        ProviderScope.containerOf(
          tester.element(choice),
        ).read(floatingNavigationProvider),
        false,
      );
      expect(
        (await SharedPreferences.getInstance()).getBool('floating_navigation'),
        false,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Cached switches appear without a spinner and refresh in place', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'notification_preferences_test-user': '{"notify_comments":false}',
    });
    final gate = Completer<NotificationPreferences>();
    final repo = _FakeNotificationPreferencesRepository()..fetchGate = gate;
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();
    SwitchListTile comments() => tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('Comments on your posts and replies to you'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(comments().value, false);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    gate.complete(const NotificationPreferences());
    await tester.pumpAndSettle();
    expect(comments().value, true);
  });

  testWidgets('Every toggle starts on by default', (tester) async {
    final repo = _FakeNotificationPreferencesRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    final switches = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(switches, hasLength(6));
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

  testWidgets('A toggle before settings load preserves the other flags', (
    tester,
  ) async {
    final gate = Completer<NotificationPreferences>();
    const serverPrefs = NotificationPreferences(digest: false);
    final repo = _FakeNotificationPreferencesRepository()
      ..stored = serverPrefs
      ..fetchGate = gate;
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Comments on your posts and replies to you'));
    await tester.pumpAndSettle();
    gate.complete(serverPrefs);
    await tester.pumpAndSettle();

    expect(repo.stored.comments, false);
    expect(repo.stored.digest, false);
    final switches = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(switches[2].value, false);
    expect(switches[3].value, false);
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

    await _scrollToAndTap(tester, 'Sign out');
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

    await _scrollToAndTap(tester, 'Sign out');
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

    await _scrollToAndTap(tester, 'Sign out');
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

      await _scrollToAndTap(tester, 'Delete account');
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

    await _scrollToAndTap(tester, 'Delete account');
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

    await _scrollToAndTap(tester, 'Delete account');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
      find.text('Failed to delete account. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'A failed toggle rolls back independently of a concurrent write',
    (tester) async {
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
      expect(repo.stored.comments, true);
      expect(repo.stored.digest, false);
    },
  );
}
