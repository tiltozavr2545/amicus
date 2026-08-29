import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/connections/connections_repository.dart';
import 'package:amicus/features/rooms/room_details_screen.dart';
import 'package:amicus/features/rooms/rooms_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';

class _FakeRoomsRepository implements RoomsRepository {
  /// What the mute switch asked for, in order — the switch is only
  /// meaningful if what it flips actually reaches the repository.
  final List<bool> mutedSent = [];

  @override
  Future<void> setRoomMuted({
    required String roomId,
    required bool muted,
  }) async => mutedSent.add(muted);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Room _room({
  required bool isDirect,
  String ownerId = 'me',
  String? avatarPath,
  bool notificationsMuted = false,
}) => Room(
  id: 'room-1',
  name: isDirect ? null : 'Дача',
  isDirect: isDirect,
  avatarPath: avatarPath,
  ownerId: ownerId,
  createdAt: DateTime.utc(2026, 8, 26),
  notificationsMuted: notificationsMuted,
  members: const [
    RoomMember(userId: 'me', name: 'Тимофей'),
    RoomMember(userId: 'anya', name: 'Аня'),
  ],
);

/// Only what the connect button reads; everything else is `noSuchMethod`.
class _FakeConnectionsRepository implements ConnectionsRepository {
  final List<String> requestedIds = [];

  @override
  Future<bool> requestConnection(String userId) async {
    requestedIds.add(userId);
    return false;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _wrap(
  Room room, {
  _FakeRoomsRepository? repo,
  _FakeConnectionsRepository? connections,
  List<Friend> friends = const [],
  List<ConnectionRequest> requests = const [],
}) => ProviderScope(
  overrides: [
    currentUserIdProvider.overrideWithValue('me'),
    roomsRepositoryProvider.overrideWithValue(repo ?? _FakeRoomsRepository()),
    myRoomsProvider.overrideWith((ref) => [room]),
    connectionsRepositoryProvider.overrideWithValue(
      connections ?? _FakeConnectionsRepository(),
    ),
    friendsProvider.overrideWith((ref) => friends),
    connectionRequestsProvider.overrideWith((ref) => requests),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const RoomDetailsScreen(roomId: 'room-1'),
  ),
);

void main() {
  testWidgets('a group room names its owner and offers the owner controls', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_room(isDirect: false)));
    await tester.pumpAndSettle();

    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Add member'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  testWidgets('a two-person room shows no ownership at all', (tester) async {
    // The row exists in the database — someone has the lowest `seq` — but
    // there is nothing an owner could do here, so the label would only invite
    // the question of why one of the two names carries it.
    await tester.pumpWidget(_wrap(_room(isDirect: true)));
    await tester.pumpAndSettle();

    expect(find.text('Owner'), findsNothing);
    expect(find.text('Add member'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    // Leaving is still on offer: it is the one thing either side can do.
    expect(find.text('Leave room'), findsOneWidget);
  });

  testWidgets('the owner of a group room can set a picture for it', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_room(isDirect: false)));
    await tester.pumpAndSettle();

    expect(find.text('Change picture'), findsOneWidget);
    // Nothing to remove until there is one.
    expect(find.text('Remove picture'), findsNothing);
  });

  testWidgets('a room that has a picture can lose it again', (tester) async {
    await tester.pumpWidget(
      _wrap(_room(isDirect: false, avatarPath: 'rooms/room-1/pic.jpg')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remove picture'), findsOneWidget);
  });

  testWidgets('a two-person room has no picture of its own', (tester) async {
    // It is the other person, and wears their avatar — there is nothing for
    // an owner to replace.
    await tester.pumpWidget(_wrap(_room(isDirect: true)));
    await tester.pumpAndSettle();

    expect(find.text('Change picture'), findsNothing);
    expect(find.text('Remove picture'), findsNothing);
  });

  testWidgets('a member of a group room cannot touch the picture', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_room(isDirect: false, ownerId: 'anya')));
    await tester.pumpAndSettle();

    expect(find.text('Change picture'), findsNothing);
  });

  testWidgets('a member of a group room sees no owner controls', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_room(isDirect: false, ownerId: 'anya')));
    await tester.pumpAndSettle();

    // The owner is still named — knowing who runs the room is useful — but
    // the buttons belong to them alone.
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Add member'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
  });

  testWidgets('muting a room sends the flag and is not an owner-only control', (
    tester,
  ) async {
    // A member, not the owner: silencing a room is about this viewer's own
    // phone, so everyone in the room gets the switch.
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(
      _wrap(_room(isDirect: false, ownerId: 'anya'), repo: repo),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    // The switch reads "notifications on", so turning it off means muted.
    expect(repo.mutedSent, [true]);
  });

  testWidgets('an already muted room shows the switch off', (tester) async {
    await tester.pumpWidget(
      _wrap(_room(isDirect: false, notificationsMuted: true)),
    );
    await tester.pumpAndSettle();

    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.value, isFalse);
  });

  testWidgets('a room peer who is not a connection can be asked to be one', (
    tester,
  ) async {
    final connections = _FakeConnectionsRepository();
    await tester.pumpWidget(
      _wrap(_room(isDirect: false), connections: connections),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_add_alt));
    await tester.pumpAndSettle();

    expect(connections.requestedIds, ['anya']);
  });

  testWidgets('an existing connection is not asked again', (tester) async {
    // The relationship exists, and this screen is not where it is managed.
    await tester.pumpWidget(
      _wrap(
        _room(isDirect: false),
        friends: [
          Friend(
            userId: 'anya',
            name: 'Аня',
            connectedAt: DateTime.utc(2026, 8, 1),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.person_add_alt), findsNothing);
  });

  testWidgets('an ask already sent says so instead of offering again', (
    tester,
  ) async {
    // Either direction: asking into a silence twice is what this prevents.
    await tester.pumpWidget(
      _wrap(
        _room(isDirect: false),
        requests: const [
          ConnectionRequest(
            id: 'req-1',
            otherId: 'anya',
            otherName: 'Аня',
            isIncoming: false,
            isPending: true,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.person_add_alt), findsNothing);
    expect(find.text('Request sent'), findsOneWidget);
  });

  testWidgets('an ask that was declined does not offer to ask again', (
    tester,
  ) async {
    // The regression this pair of tests exists for. The screen used to be
    // handed only `status = 'pending'` rows, so a declined request vanished
    // from it — and since a decline is deliberately silent, nothing else told
    // the sender either. The button came back for someone
    // `connection_requests_pair_key` can never accept a second row for, and
    // answered PT409 on every tap, forever.
    await tester.pumpWidget(
      _wrap(
        _room(isDirect: false),
        requests: const [
          ConnectionRequest(
            id: 'req-1',
            otherId: 'anya',
            otherName: 'Аня',
            isIncoming: false,
            isPending: false,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.person_add_alt), findsNothing);
    expect(find.text('Request sent'), findsOneWidget);
  });

  testWidgets('declining someone leaves you free to ask them yourself', (
    tester,
  ) async {
    // The other half of the same rule, and why "any request at all" is the
    // wrong test: the unique index is on (requester, recipient), so a request
    // this viewer refused does not stand in the way of one they send. That is
    // their own decision rather than a repeated plea — see data-model.md.
    await tester.pumpWidget(
      _wrap(
        _room(isDirect: false),
        requests: const [
          ConnectionRequest(
            id: 'req-1',
            otherId: 'anya',
            otherName: 'Аня',
            isIncoming: true,
            isPending: false,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.person_add_alt), findsOneWidget);
    expect(find.text('Request sent'), findsNothing);
  });
}
