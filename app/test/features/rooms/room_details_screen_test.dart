import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/rooms/room_details_screen.dart';
import 'package:amicus/features/rooms/rooms_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';

class _FakeRoomsRepository implements RoomsRepository {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Room _room({
  required bool isDirect,
  String ownerId = 'me',
  String? avatarPath,
}) => Room(
  id: 'room-1',
  name: isDirect ? null : 'Дача',
  isDirect: isDirect,
  avatarPath: avatarPath,
  ownerId: ownerId,
  createdAt: DateTime.utc(2026, 8, 26),
  members: const [
    RoomMember(userId: 'me', name: 'Тимофей'),
    RoomMember(userId: 'anya', name: 'Аня'),
  ],
);

Widget _wrap(Room room) => ProviderScope(
  overrides: [
    currentUserIdProvider.overrideWithValue('me'),
    roomsRepositoryProvider.overrideWithValue(_FakeRoomsRepository()),
    myRoomsProvider.overrideWith((ref) => [room]),
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
}
