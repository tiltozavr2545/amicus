import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/rooms/room_chat_screen.dart';
import 'package:amicus/features/rooms/rooms_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';
import 'package:amicus/shared/media_picking.dart';

/// Only the members the chat screen calls need real behaviour; the rest
/// satisfy the `implements` contract via `noSuchMethod`, the same trick the
/// feed screen tests use.
class _FakeRoomsRepository implements RoomsRepository {
  _FakeRoomsRepository({this.messages = const []});

  List<RoomMessage> messages;

  int markReadCalls = 0;
  final List<String> sentTexts = [];
  final List<String> deletedIds = [];
  bool sendThrows = false;

  /// The screen's realtime handlers, captured so a test can play the part of
  /// the server and push a message in.
  void Function(RoomMessage)? onInsert;
  void Function(RoomMessage)? onUpdate;
  int unsubscribeCalls = 0;

  @override
  Future<List<RoomMessage>> fetchMessages({
    required String roomId,
    RoomMessage? before,
    int limit = 50,
  }) async => before == null ? messages : const [];

  /// Attachments each send carried — the attach button is only meaningful if
  /// what it collects reaches the repository.
  final List<List<PickedMedia>> sentMedia = [];

  @override
  Future<RoomMessage> sendMessage({
    required String roomId,
    required String authorId,
    required String text,
    required String clientToken,
    List<PickedMedia> media = const [],
  }) async {
    sentTexts.add(text);
    sentMedia.add(media);
    if (sendThrows) throw Exception('rejected');
    return RoomMessage(
      id: 'sent-${sentTexts.length}',
      roomId: roomId,
      authorId: authorId,
      text: text,
      createdAt: DateTime.utc(2026, 8, 26, 19),
    );
  }

  @override
  Future<void> deleteMessage(String messageId) async =>
      deletedIds.add(messageId);

  @override
  Future<void> markRoomRead(String roomId) async => markReadCalls++;

  @override
  void Function() subscribeToMessages({
    required String roomId,
    required void Function(RoomMessage message) onInsert,
    required void Function(RoomMessage message) onUpdate,
  }) {
    this.onInsert = onInsert;
    this.onUpdate = onUpdate;
    return () => unsubscribeCalls++;
  }

  @override
  Future<Map<String, String>> resolveMediaUrls(List<String> paths) async =>
      const {};

  @override
  Future<List<RoomMemberReceipt>> fetchMemberReceipts(String roomId) async =>
      const [];

  @override
  void Function() subscribeToMemberReceipts({
    required String roomId,
    required void Function(RoomMemberReceipt receipt) onUpdate,
  }) => () {};

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RoomMessage _message({
  required String id,
  required String authorId,
  String text = 'привет',
  DateTime? createdAt,
  DateTime? deletedAt,
  List<RoomMessageMedia> media = const [],
}) => RoomMessage(
  id: id,
  roomId: 'room-1',
  authorId: authorId,
  text: text,
  createdAt: createdAt ?? DateTime.utc(2026, 8, 26, 18),
  deletedAt: deletedAt,
  media: media,
);

final _room = Room(
  id: 'room-1',
  name: 'Дача',
  isDirect: false,
  ownerId: 'me',
  createdAt: DateTime.utc(2026, 8, 26),
  members: const [
    RoomMember(userId: 'me', name: 'Тимофей'),
    RoomMember(userId: 'anya', name: 'Аня'),
  ],
);

Widget _wrap(_FakeRoomsRepository repo, {List<Room> rooms = const []}) {
  return ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('me'),
      roomsRepositoryProvider.overrideWithValue(repo),
      myRoomsProvider.overrideWith((ref) => rooms.isEmpty ? [_room] : rooms),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const RoomChatScreen(roomId: 'room-1'),
    ),
  );
}

void main() {
  testWidgets('shows the room name and its messages', (tester) async {
    final repo = _FakeRoomsRepository(
      messages: [
        _message(id: 'm2', authorId: 'me', text: 'моё сообщение'),
        _message(id: 'm1', authorId: 'anya', text: 'её сообщение'),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('Дача'), findsOneWidget);
    expect(find.text('моё сообщение'), findsOneWidget);
    expect(find.text('её сообщение'), findsOneWidget);
    // Someone else's message is signed; one's own is not — which side of the
    // screen it sits on already says who wrote it.
    expect(find.text('Аня'), findsOneWidget);
    expect(find.text('Тимофей'), findsNothing);
  });

  testWidgets('opening the chat marks it read', (tester) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(repo.markReadCalls, 1);
  });

  testWidgets('a deleted message is a tombstone, not a gap', (tester) async {
    final repo = _FakeRoomsRepository(
      messages: [
        _message(
          id: 'm1',
          authorId: 'anya',
          text: '',
          deletedAt: DateTime.utc(2026, 8, 26, 18, 5),
        ),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('Message deleted'), findsOneWidget);
  });

  testWidgets('a message can be attachments with no caption at all', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository(
      messages: [
        _message(
          id: 'm1',
          authorId: 'anya',
          text: '',
          media: const [
            RoomMessageMedia(
              storagePath: 'messages/room-1/anya/t/a.jpg',
              isVideo: false,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    // The bubble is the photo: attachments rendered, and no caption line
    // where there is no caption (the tombstone label is the only text a
    // bubble ever shows in place of one).
    expect(find.byKey(const ValueKey('message-media-m1')), findsOneWidget);
    expect(find.text('Message deleted'), findsNothing);
  });

  testWidgets('sending posts the text and clears the field', (tester) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '  до встречи  ');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(repo.sentTexts, ['до встречи']);
    expect(find.text('до встречи'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
  });

  testWidgets('an empty message is not sent', (tester) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(repo.sentTexts, isEmpty);
  });

  testWidgets('a failed send keeps the draft and says so', (tester) async {
    final repo = _FakeRoomsRepository()..sendThrows = true;
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'не уйдёт');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.text('Failed to send. Please try again.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'не уйдёт',
    );
  });

  testWidgets('a message arriving over realtime appears in the list', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    repo.onInsert!(
      _message(id: 'live-1', authorId: 'anya', text: 'только что пришло'),
    );
    await tester.pumpAndSettle();

    expect(find.text('только что пришло'), findsOneWidget);
    // Reading a room while looking at it is what silences its pushes.
    expect(repo.markReadCalls, 2);
  });

  testWidgets('the echo of an own message does not duplicate it', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'одно сообщение');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    // The sender's own insert comes back over the subscription too.
    repo.onInsert!(
      _message(id: 'sent-1', authorId: 'me', text: 'одно сообщение'),
    );
    await tester.pumpAndSettle();

    expect(find.text('одно сообщение'), findsOneWidget);
  });

  testWidgets('leaving the screen unsubscribes', (tester) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(repo.unsubscribeCalls, 1);
  });
}
