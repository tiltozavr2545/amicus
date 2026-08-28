import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/connections/connections_repository.dart';
import 'package:amicus/features/connections/connections_screen.dart';
import 'package:amicus/features/feed/feed_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';

/// Records calls so the tests can assert whether activation actually reached
/// the repository. No Supabase client is needed — the provider is overridden.
class _FakeConnectionsRepository implements ConnectionsRepository {
  List<Friend> friends = [];
  int activateCalls = 0;
  String? lastCode;

  /// Makes [muteUser] fail, so a test can check the failure path.
  bool muteThrows = false;

  int muteCalls = 0;
  int unmuteCalls = 0;
  int blockCalls = 0;
  int unblockCalls = 0;
  String? lastMutedId;
  String? lastUnmutedId;
  String? lastBlockedId;
  String? lastUnblockedId;

  int createCalls = 0;
  int rotateCalls = 0;

  /// Requests recorded by the room screen / the requests section.
  final List<String> requestedIds = [];
  final List<(String, bool)> answeredRequests = [];
  List<ConnectionRequest> pendingRequests = [];

  @override
  Future<List<ConnectionRequest>> fetchPendingRequests(String viewerId) async =>
      pendingRequests;

  @override
  Future<bool> requestConnection(String userId) async {
    requestedIds.add(userId);
    return false;
  }

  @override
  Future<void> respondToRequest({
    required String requestId,
    required bool accept,
  }) async => answeredRequests.add((requestId, accept));

  @override
  Future<String> createInviteLink() async {
    createCalls++;
    return 'stub-code';
  }

  /// A different string on purpose: the whole point of rotation is that the
  /// code on screen changes, which is exactly what the old idempotent
  /// `createInviteLink` could not do.
  @override
  Future<String> rotateInviteLink() async {
    rotateCalls++;
    return 'rotated-code';
  }

  /// Thrown instead of activating, so a test can drive the error branch.
  Object? activateError;

  @override
  Future<ActivatedConnection> activateInviteLink(String code) async {
    activateCalls++;
    lastCode = code;
    if (activateError != null) throw activateError!;
    return const ActivatedConnection(ownerName: 'Owner');
  }

  @override
  Future<List<Friend>> fetchFriends(String currentUserId) async => friends;

  @override
  Future<void> muteUser({
    required String muterId,
    required String mutedId,
  }) async {
    if (muteThrows) throw Exception('mute failed');
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
    unblockEverywhere(blockedId);
  }

  @override
  Future<List<BlockedUser>> fetchBlockedUsers(String currentUserId) async =>
      blockedUsers;

  int favoriteCalls = 0;
  int unfavoriteCalls = 0;
  String? lastFavoritedId;
  String? lastUnfavoritedId;

  @override
  Future<void> favoriteUser({
    required String userId,
    required String favoriteId,
  }) async {
    favoriteCalls++;
    lastFavoritedId = favoriteId;
  }

  @override
  Future<void> unfavoriteUser({
    required String userId,
    required String favoriteId,
  }) async {
    unfavoriteCalls++;
    lastUnfavoritedId = favoriteId;
  }

  /// Backing store for the round-trip test below: unblocking has to be visible
  /// to a *later* fetchFriends, the way it is on the server.
  List<BlockedUser> blockedUsers = [];

  void unblockEverywhere(String userId) {
    blockedUsers = blockedUsers.where((b) => b.userId != userId).toList();
    friends = [
      for (final f in friends)
        if (f.userId == userId)
          Friend(
            userId: f.userId,
            name: f.name,
            connectedAt: f.connectedAt,
            avatarPath: f.avatarPath,
            isMuted: f.isMuted,
          )
        else
          f,
    ];
  }
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

  testWidgets('The first tap mints a code without asking anything', (
    tester,
  ) async {
    final repo = _FakeConnectionsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Create invite code'));
    await tester.pumpAndSettle();

    expect(repo.createCalls, 1);
    expect(repo.rotateCalls, 0);
    expect(find.text('stub-code'), findsOneWidget);
  });

  testWidgets(
    'Creating a new code asks first, and leaves the old one alone on cancel',
    (tester) async {
      final repo = _FakeConnectionsRepository();
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Create invite code'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Create new code'));
      await tester.pumpAndSettle();
      expect(find.text('Create a new code?'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      // Whoever already holds the code keeps it: nothing was revoked.
      expect(repo.rotateCalls, 0);
      expect(find.text('stub-code'), findsOneWidget);
    },
  );

  testWidgets(
    'Confirming replaces the code, rather than handing back the same one',
    (tester) async {
      final repo = _FakeConnectionsRepository();
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Create invite code'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Create new code'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Create new code'));
      await tester.pumpAndSettle();

      // The rotation RPC, not the idempotent one — calling createInviteLink
      // again is what used to redisplay the identical, unrevokable code.
      expect(repo.rotateCalls, 1);
      expect(repo.createCalls, 1);
      expect(find.text('rotated-code'), findsOneWidget);
      expect(find.text('stub-code'), findsNothing);
    },
  );

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

  // activate_invite_link() raises three errors the user needs to hear apart,
  // tagged with stable SQLSTATEs so the wording can live in the ARB files
  // instead of being hardcoded English inside a migration.
  testWidgets('A known activation error is shown localized, by code', (
    tester,
  ) async {
    final repo = _FakeConnectionsRepository()
      ..activateError = const PostgrestException(
        message: 'Invite code already used',
        code: 'PT409',
      );
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'abc123');
    await tester.tap(find.widgetWithText(FilledButton, 'Activate'));
    await tester.pump();

    expect(
      find.text('This invite code has already been used.'),
      findsOneWidget,
    );
  });

  // The same exception type also carries statement timeouts and constraint
  // violations, whose raw text names tables and constraints. Those must not
  // reach the screen.
  testWidgets('An unexpected database error is not shown raw', (tester) async {
    final repo = _FakeConnectionsRepository()
      ..activateError = const PostgrestException(
        message:
            'insert or update on table "connections" violates foreign key '
            'constraint "connections_user_a_id_fkey"',
        code: '23503',
      );
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'abc123');
    await tester.tap(find.widgetWithText(FilledButton, 'Activate'));
    await tester.pump();

    expect(find.textContaining('connections_user_a_id_fkey'), findsNothing);
    expect(find.textContaining('violates foreign key'), findsNothing);
    expect(find.text('Unexpected error. Please try again.'), findsOneWidget);
  });

  // The feed tab keeps its loaded page alive in the shell's IndexedStack, so
  // hiding (or un-hiding) an author has to reach it through the refresh tick —
  // otherwise a blocked person's posts stay on screen until a pull-to-refresh.
  testWidgets('Muting bumps the feed refresh tick', (tester) async {
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

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ConnectionsScreen)),
    );
    final before = container.read(feedRefreshTickProvider);

    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Mute'));
    await tester.pump();

    expect(repo.muteCalls, 1);
    expect(container.read(feedRefreshTickProvider), before + 1);
  });

  testWidgets('Unblocking bumps the feed refresh tick', (tester) async {
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

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ConnectionsScreen)),
    );
    final before = container.read(feedRefreshTickProvider);

    await tester.tap(find.byTooltip('Unblock'));
    await tester.pump();

    expect(repo.unblockCalls, 1);
    expect(container.read(feedRefreshTickProvider), before + 1);
  });

  // The "Blocked users" screen is pushed *over* this one, so ConnectionsScreen
  // stays mounted and keeps friendsProvider (autoDispose) alive with the flags
  // it fetched before. Unblocking there has to invalidate it, or popping back
  // lands on a row still marked blocked.
  testWidgets('Unblocking on the blocked-users screen refreshes the '
      'connections list behind it', (tester) async {
    final repo = _FakeConnectionsRepository()
      ..friends = [
        Friend(
          userId: 'friend-1',
          name: 'Alice',
          connectedAt: DateTime(2026, 1, 1),
          isBlocked: true,
        ),
      ]
      ..blockedUsers = [BlockedUser(userId: 'friend-1', name: 'Alice')];
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    // Alice starts out blocked: her block button offers "Unblock".
    expect(find.byTooltip('Unblock'), findsOneWidget);

    await tester.tap(find.byTooltip('Blocked users'));
    await tester.pumpAndSettle();
    expect(find.text('Blocked'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Unblock'));
    await tester.pump();
    expect(repo.unblockCalls, 1);

    await tester.pageBack();
    await tester.pumpAndSettle();

    // Back on the connections list, the row must have caught up.
    expect(find.byTooltip('Unblock'), findsNothing);
    expect(find.byTooltip('Block'), findsOneWidget);
  });

  testWidgets('A failed mute does not bump the feed refresh tick', (
    tester,
  ) async {
    final repo = _FakeConnectionsRepository()
      ..muteThrows = true
      ..friends = [
        Friend(
          userId: 'friend-1',
          name: 'Alice',
          connectedAt: DateTime(2026, 1, 1),
        ),
      ];
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ConnectionsScreen)),
    );
    final before = container.read(feedRefreshTickProvider);

    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Mute'));
    await tester.pump();

    expect(container.read(feedRefreshTickProvider), before);
  });

  group('connection requests', () {
    testWidgets('an incoming request can be accepted', (tester) async {
      final repo = _FakeConnectionsRepository()
        ..pendingRequests = const [
          ConnectionRequest(
            id: 'req-1',
            otherId: 'anya',
            otherName: 'Аня',
            isIncoming: true,
          ),
        ];
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      expect(find.text('Аня'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      expect(repo.answeredRequests, [('req-1', true)]);
    });

    testWidgets('an incoming request can be declined', (tester) async {
      final repo = _FakeConnectionsRepository()
        ..pendingRequests = const [
          ConnectionRequest(
            id: 'req-1',
            otherId: 'anya',
            otherName: 'Аня',
            isIncoming: true,
          ),
        ];
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(repo.answeredRequests, [('req-1', false)]);
    });

    testWidgets('own outgoing request is not something to answer', (
      tester,
    ) async {
      // It shows on the room screen as "asked"; here it would be a request
      // from oneself with an Accept button under it.
      final repo = _FakeConnectionsRepository()
        ..pendingRequests = const [
          ConnectionRequest(
            id: 'req-1',
            otherId: 'anya',
            otherName: 'Аня',
            isIncoming: false,
          ),
        ];
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      expect(find.text('Connection requests'), findsNothing);
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('with nothing pending the section is not there at all', (
      tester,
    ) async {
      final repo = _FakeConnectionsRepository();
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      expect(find.text('Connection requests'), findsNothing);
    });
  });
}
