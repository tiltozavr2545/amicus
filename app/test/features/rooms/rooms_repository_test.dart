import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/rooms/rooms_repository.dart';

Room _room({
  String? name,
  bool isDirect = false,
  List<RoomMember> members = const [],
}) => Room(
  id: 'room-1',
  name: name,
  isDirect: isDirect,
  ownerId: 'me',
  createdAt: DateTime.utc(2026, 8, 26),
  members: members,
);

const _me = RoomMember(userId: 'me', name: 'Тимофей');
const _anya = RoomMember(userId: 'anya', name: 'Аня');
const _boris = RoomMember(userId: 'boris', name: 'Борис');

void main() {
  group('roomDisplayName', () {
    test('a two-person room is named after the other person', () {
      final room = _room(isDirect: true, members: const [_me, _anya]);

      expect(roomDisplayName(room, 'me', fallback: 'Room'), 'Аня');
    });

    test('and the same room reads as my name to the other side', () {
      final room = _room(isDirect: true, members: const [_me, _anya]);

      expect(roomDisplayName(room, 'anya', fallback: 'Room'), 'Тимофей');
    });

    test('an unnamed group lists everyone but the viewer', () {
      final room = _room(members: const [_me, _anya, _boris]);

      expect(roomDisplayName(room, 'me', fallback: 'Room'), 'Аня, Борис');
    });

    test('a named room keeps its name for everyone', () {
      final room = _room(name: 'Дача', members: const [_me, _anya, _boris]);

      expect(roomDisplayName(room, 'me', fallback: 'Room'), 'Дача');
      expect(roomDisplayName(room, 'anya', fallback: 'Room'), 'Дача');
    });

    test('falls back when the viewer is the only one left', () {
      // A group can sit at one member between someone leaving and the list
      // being refetched; an empty title would be worse than a generic one.
      final room = _room(members: const [_me]);

      expect(roomDisplayName(room, 'me', fallback: 'Комната'), 'Комната');
    });

    test('an empty stored name is treated as no name at all', () {
      final room = _room(name: '', members: const [_me, _anya]);

      expect(roomDisplayName(room, 'me', fallback: 'Room'), 'Аня');
    });
  });

  group('RoomMessage.fromRow', () {
    test('reads a message with its embedded author', () {
      final message = RoomMessage.fromRow({
        'id': 'msg-1',
        'room_id': 'room-1',
        'author_id': 'anya',
        'text': 'привет',
        'created_at': '2026-08-26T18:05:00+00:00',
        'deleted_at': null,
        'author': {'name': 'Аня'},
      });

      expect(message.text, 'привет');
      expect(message.authorName, 'Аня');
      expect(message.isDeleted, isFalse);
      expect(message.createdAt, DateTime.utc(2026, 8, 26, 18, 5).toLocal());
    });

    test('a tombstone keeps its place and loses its text', () {
      final message = RoomMessage.fromRow({
        'id': 'msg-1',
        'room_id': 'room-1',
        'author_id': 'anya',
        'text': '',
        'created_at': '2026-08-26T18:05:00+00:00',
        'deleted_at': '2026-08-26T18:06:00+00:00',
        'author': {'name': 'Аня'},
      });

      expect(message.isDeleted, isTrue);
      expect(message.text, isEmpty);
    });

    test('a row straight off realtime has no embedded author', () {
      // Realtime hands over the raw row — no join, so no name. The screen
      // resolves it from the room's members instead.
      final message = RoomMessage.fromRow({
        'id': 'msg-1',
        'room_id': 'room-1',
        'author_id': 'anya',
        'text': 'привет',
        'created_at': '2026-08-26T18:05:00+00:00',
        'deleted_at': null,
      });

      expect(message.authorName, isNull);
      expect(message.authorId, 'anya');
    });
  });

  group('Room.fromRow', () {
    test('reads a row of my_rooms(), members and all', () {
      final room = Room.fromRow({
        'id': 'room-1',
        'name': null,
        'is_direct': false,
        'owner_id': 'me',
        'created_at': '2026-08-26T10:00:00+00:00',
        'members': [
          {'id': 'me', 'name': 'Тимофей', 'avatar_path': null},
          {'id': 'anya', 'name': 'Аня', 'avatar_path': 'avatars/anya/1.jpg'},
        ],
      });

      expect(room.id, 'room-1');
      expect(room.name, isNull);
      expect(room.isDirect, isFalse);
      expect(room.isOwnedBy('me'), isTrue);
      expect(room.isOwnedBy('anya'), isFalse);
      expect(room.members.map((m) => m.name), ['Тимофей', 'Аня']);
      expect(room.members.last.avatarPath, 'avatars/anya/1.jpg');
      expect(room.othersThan('me').single.userId, 'anya');
    });

    test('reads the chat half: last message, its author, unread count', () {
      final room = Room.fromRow({
        'id': 'room-1',
        'name': 'Дача',
        'is_direct': false,
        'owner_id': 'me',
        'created_at': '2026-08-26T10:00:00+00:00',
        'last_message_at': '2026-08-26T18:05:00+00:00',
        'last_message_text': 'приду позже',
        'last_message_author_id': 'anya',
        'unread_count': 3,
        'members': [
          {'id': 'me', 'name': 'Тимофей', 'avatar_path': null},
          {'id': 'anya', 'name': 'Аня', 'avatar_path': null},
        ],
      });

      expect(room.lastMessageAt, DateTime.utc(2026, 8, 26, 18, 5).toLocal());
      expect(room.lastMessageText, 'приду позже');
      expect(room.memberById(room.lastMessageAuthorId)?.name, 'Аня');
      expect(room.unreadCount, 3);
    });

    test('a room nobody has written in yet has no chat fields', () {
      final room = Room.fromRow({
        'id': 'room-1',
        'name': null,
        'is_direct': true,
        'owner_id': 'me',
        'created_at': '2026-08-26T10:00:00+00:00',
        'last_message_at': null,
        'last_message_text': null,
        'last_message_author_id': null,
        'unread_count': 0,
        'members': [
          {'id': 'me', 'name': 'Тимофей', 'avatar_path': null},
        ],
      });

      expect(room.lastMessageAt, isNull);
      expect(room.lastMessageText, isNull);
      expect(room.unreadCount, 0);
      // The author of a message from someone who has since left the room is
      // not in `members` — every caller has to survive that.
      expect(room.memberById('gone'), isNull);
      expect(room.memberById(null), isNull);
    });
  });
}
