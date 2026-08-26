import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/connections/connections_screen.dart';
import 'package:amicus/features/connections/friend_profile_screen.dart';
import 'package:amicus/features/rooms/room_details_screen.dart';
import 'package:amicus/features/rooms/rooms_repository.dart';
import 'package:amicus/features/rooms/rooms_screen.dart';
import 'package:amicus/l10n/app_localizations.dart';

class _FakeRoomsRepository implements RoomsRepository {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Room _room({
  String? name = 'Дача',
  bool isDirect = false,
  int unreadCount = 0,
  String? lastMessageText,
  String? lastMessageAuthorId,
}) => Room(
  id: 'room-1',
  name: name,
  isDirect: isDirect,
  ownerId: 'me',
  createdAt: DateTime.utc(2026, 8, 26),
  unreadCount: unreadCount,
  lastMessageText: lastMessageText,
  lastMessageAuthorId: lastMessageAuthorId,
  members: const [
    RoomMember(userId: 'me', name: 'Тимофей'),
    RoomMember(userId: 'anya', name: 'Аня'),
  ],
);

Widget _wrap(List<Room> rooms) => ProviderScope(
  overrides: [
    currentUserIdProvider.overrideWithValue('me'),
    roomsRepositoryProvider.overrideWithValue(_FakeRoomsRepository()),
    myRoomsProvider.overrideWith((ref) => rooms),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const RoomsScreen(),
  ),
);

void main() {
  testWidgets('tapping a two-person room\'s avatar opens that person', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap([_room(name: null, isDirect: true)]));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FriendAvatar));
    // Not pumpAndSettle: the profile screen loads its posts and photos, and
    // its progress indicator spins forever in a test with no backend, so
    // nothing ever settles. A couple of frames is all it takes to see which
    // route opened.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final screen = tester.widget<FriendProfileScreen>(
      find.byType(FriendProfileScreen),
    );
    // The avatar belongs to the other member, so that is whose profile opens —
    // never the viewer's own.
    expect(screen.friendId, 'anya');
    expect(screen.friendName, 'Аня');
  });

  testWidgets('a group without a picture wears no member\'s face', (
    tester,
  ) async {
    // Borrowing one member's avatar made the row look like that person, and
    // tapping it opened their profile — for a room with several others in it,
    // chosen by nothing but who joined first.
    await tester.pumpWidget(_wrap([_room()]));
    await tester.pumpAndSettle();

    expect(find.byType(FriendAvatar), findsNothing);
    expect(find.byIcon(Icons.group), findsOneWidget);

    await tester.tap(find.byIcon(Icons.group));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(RoomDetailsScreen), findsOneWidget);
  });

  testWidgets('a two-person room is named after the other person', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap([_room(name: null, isDirect: true)]));
    await tester.pumpAndSettle();

    expect(find.text('Аня'), findsOneWidget);
  });

  testWidgets('the last message is the subtitle, signed by its author', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap([
        _room(lastMessageText: 'приду позже', lastMessageAuthorId: 'anya'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Аня: приду позже'), findsOneWidget);
  });

  testWidgets('unread messages show as a badge on the chat button', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap([_room(unreadCount: 3)]));
    await tester.pumpAndSettle();

    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('a room with nothing said in it shows its member count', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap([_room()]));
    await tester.pumpAndSettle();

    expect(find.text('2 members'), findsOneWidget);
  });
}
