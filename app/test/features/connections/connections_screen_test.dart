import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/connections/connections_repository.dart';
import 'package:amicus/features/connections/connections_screen.dart';
import 'package:amicus/l10n/app_localizations.dart';

/// Records calls so the tests can assert whether activation actually reached
/// the repository. No Supabase client is needed — the provider is overridden.
class _FakeConnectionsRepository implements ConnectionsRepository {
  int activateCalls = 0;
  String? lastCode;

  @override
  Future<String> createInviteLink() async => 'stub-code';

  @override
  Future<ActivatedConnection> activateInviteLink(String code) async {
    activateCalls++;
    lastCode = code;
    return const ActivatedConnection(ownerId: 'owner-1', ownerName: 'Owner');
  }

  @override
  Future<List<Friend>> fetchFriends(String currentUserId) async => [];
}

Widget _wrap(_FakeConnectionsRepository repo) {
  return ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('test-user'),
      connectionsRepositoryProvider.overrideWithValue(repo),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ConnectionsScreen(),
    ),
  );
}

void main() {
  setUp(() {
    // ThemeToggleSwitch (in the AppBar) reads shared_preferences on build.
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Activate with an empty code shows an error and never calls the '
      'repository', (tester) async {
    final repo = _FakeConnectionsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Activate'));
    await tester.pump();

    expect(find.text('Enter an invite code'), findsOneWidget);
    expect(repo.activateCalls, 0);
  });

  testWidgets('Activate with a non-empty code calls the repository', (
    tester,
  ) async {
    final repo = _FakeConnectionsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '  abc123  ');
    await tester.tap(find.widgetWithText(FilledButton, 'Activate'));
    await tester.pump();

    expect(repo.activateCalls, 1);
    // The screen trims the code before handing it off.
    expect(repo.lastCode, 'abc123');
  });
}
