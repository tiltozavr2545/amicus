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
  List<Friend> friends = [];
  int activateCalls = 0;
  String? lastCode;

  int muteCalls = 0;
  int unmuteCalls = 0;
  int blockCalls = 0;
  int unblockCalls = 0;
  String? lastMutedId;
  String? lastUnmutedId;
  String? lastBlockedId;
  String? lastUnblockedId;

  @override
  Future<String> createInviteLink() async => 'stub-code';

  @override
  Future<ActivatedConnection> activateInviteLink(String code) async {
    activateCalls++;
    lastCode = code;
    return const ActivatedConnection(ownerId: 'owner-1', ownerName: 'Owner');
  }

  @override
  Future<List<Friend>> fetchFriends(String currentUserId) async => friends;

  @override
  Future<void> muteUser({
    required String muterId,
    required String mutedId,
  }) async {
    muteCalls++;
    lastMutedId = mutedId;
  }

  @override
  Future<void> unmuteUser({
    required String muterId,
    required String mutedId,
  }) async {
    unmuteCalls++;
    lastUnmutedId = mutedId;
  }

  @override
  Future<void> blockUser({
    required String blockerId,
    required String blockedId,
  }) async {
    blockCalls++;
    lastBlockedId = blockedId;
  }

  @override
  Future<void> unblockUser({
    required String blockerId,
    required String blockedId,
  }) async {
    unblockCalls++;
    lastUnblockedId = blockedId;
  }

  @override
  Future<List<BlockedUser>> fetchBlockedUsers(String currentUserId) async => [];
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

  testWidgets(
    'Muting an unmuted friend shows a confirmation dialog and only calls '
    'the repository once confirmed',
    (tester) async {
      final repo = _FakeConnectionsRepository()
        ..friends = [
          Friend(
            userId: 'friend-1',
            name: 'Alice',
            connectedAt: DateTime(2026, 1, 1),
          ),
        ];
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      await tester.tap(find.byTooltip('Mute'));
      await tester.pump();

      expect(find.text('Mute Alice?'), findsOneWidget);
      expect(repo.muteCalls, 0);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      expect(repo.muteCalls, 0);

      await tester.tap(find.byTooltip('Mute'));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Mute'));
      await tester.pump();

      expect(repo.muteCalls, 1);
      expect(repo.lastMutedId, 'friend-1');
    },
  );

  testWidgets('Tapping mute on an already-muted friend unmutes immediately '
      'without a dialog', (tester) async {
    final repo = _FakeConnectionsRepository()
      ..friends = [
        Friend(
          userId: 'friend-1',
          name: 'Alice',
          connectedAt: DateTime(2026, 1, 1),
          isMuted: true,
        ),
      ];
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.tap(find.byTooltip('Unmute'));
    await tester.pump();

    expect(find.text('Mute Alice?'), findsNothing);
    expect(repo.unmuteCalls, 1);
    expect(repo.lastUnmutedId, 'friend-1');
  });

  testWidgets(
    'Blocking an unblocked friend shows a confirmation dialog and only '
    'calls the repository once confirmed',
    (tester) async {
      final repo = _FakeConnectionsRepository()
        ..friends = [
          Friend(
            userId: 'friend-1',
            name: 'Alice',
            connectedAt: DateTime(2026, 1, 1),
          ),
        ];
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      await tester.tap(find.byTooltip('Block'));
      await tester.pump();

      expect(find.text('Block Alice?'), findsOneWidget);
      expect(repo.blockCalls, 0);

      await tester.tap(find.widgetWithText(TextButton, 'Block'));
      await tester.pump();

      expect(repo.blockCalls, 1);
      expect(repo.lastBlockedId, 'friend-1');
    },
  );

  testWidgets('Tapping block on an already-blocked friend unblocks '
      'immediately without a dialog', (tester) async {
    final repo = _FakeConnectionsRepository()
      ..friends = [
        Friend(
          userId: 'friend-1',
          name: 'Alice',
          connectedAt: DateTime(2026, 1, 1),
          isBlocked: true,
        ),
      ];
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.tap(find.byTooltip('Unblock'));
    await tester.pump();

    expect(find.text('Block Alice?'), findsNothing);
    expect(repo.unblockCalls, 1);
    expect(repo.lastUnblockedId, 'friend-1');
  });
}
