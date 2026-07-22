import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/connections/blocked_users_screen.dart';
import 'package:amicus/features/connections/connections_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';

/// Only the members `BlockedUsersScreen` actually calls need real behaviour;
/// the rest satisfy the `implements` contract.
class _FakeConnectionsRepository implements ConnectionsRepository {
  List<BlockedUser> blockedUsers = [];
  int unblockCalls = 0;
  String? lastUnblockedId;

  @override
  Future<String> createInviteLink() async => 'stub-code';

  @override
  Future<ActivatedConnection> activateInviteLink(String code) async {
    return const ActivatedConnection(ownerId: 'owner-1', ownerName: 'Owner');
  }

  @override
  Future<List<Friend>> fetchFriends(String currentUserId) async => [];

  @override
  Future<void> muteUser({
    required String muterId,
    required String mutedId,
  }) async {}

  @override
  Future<void> unmuteUser({
    required String muterId,
    required String mutedId,
  }) async {}

  @override
  Future<void> blockUser({
    required String blockerId,
    required String blockedId,
  }) async {}

  @override
  Future<void> unblockUser({
    required String blockerId,
    required String blockedId,
  }) async {
    unblockCalls++;
    lastUnblockedId = blockedId;
  }

  @override
  Future<List<BlockedUser>> fetchBlockedUsers(String currentUserId) async =>
      blockedUsers;
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
      home: BlockedUsersScreen(),
    ),
  );
}

void main() {
  testWidgets('Shows the empty-state message when nothing is blocked', (
    tester,
  ) async {
    final repo = _FakeConnectionsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    expect(find.text("You haven't blocked anyone"), findsOneWidget);
  });

  testWidgets('Lists blocked users and unblocks without a confirmation '
      'dialog', (tester) async {
    final repo = _FakeConnectionsRepository()
      ..blockedUsers = [
        BlockedUser(
          userId: 'blocked-1',
          name: 'Bob',
          blockedAt: DateTime(2026, 1, 1),
        ),
      ];
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    expect(find.text('Bob'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Unblock'));
    await tester.pump();

    expect(repo.unblockCalls, 1);
    expect(repo.lastUnblockedId, 'blocked-1');
  });
}
