import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/delete_order.dart';
import '../../shared/media_bucket.dart';
import '../../shared/media_gallery.dart';
import '../../shared/media_picking.dart';
import '../../shared/network_timeout.dart';
import '../../shared/parse_timestamp.dart';
import '../../shared/signed_urls.dart';
import '../../shared/tolerant_upload.dart';
import '../auth/auth_providers.dart';

/// One member of a room, as the room list and the members screen show them.
class RoomMember {
  const RoomMember({required this.userId, required this.name, this.avatarPath});

  final String userId;
  final String name;
  final String? avatarPath;

  factory RoomMember.fromJson(Map<String, dynamic> json) => RoomMember(
    userId: json['id'] as String,
    name: json['name'] as String,
    avatarPath: json['avatar_path'] as String?,
  );
}

/// A room: a chat shared by [members].
///
/// [isDirect] is the two-person case, and it is a different thing rather than
/// a smaller one: it has no name of its own (each side sees the other's
/// name — see [roomDisplayName]), it can never take a third member, and it
/// dies when either side leaves. Both facts are enforced server-side; the
/// screens only hide the buttons.
class Room {
  const Room({
    required this.id,
    required this.isDirect,
    this.avatarPath,
    required this.ownerId,
    required this.createdAt,
    required this.members,
    this.name,
    this.lastMessageAt,
    this.lastMessageText,
    this.lastMessageAuthorId,
    this.lastMessageHasMedia = false,
    this.unreadCount = 0,
    this.notificationsMuted = false,
  });

  final String id;

  /// The room's own name, or null when nobody has set one — then the name is
  /// the list of the other members, assembled per viewer by [roomDisplayName]
  /// rather than stored. Storing that enumeration would have frozen it: names
  /// change and so does the membership.
  final String? name;

  /// The room's own picture, set by its owner. Only a group room can have
  /// one: a two-person room is the other person, and wears their avatar.
  final String? avatarPath;

  final bool isDirect;

  /// The member who may rename the room, add and remove people. Server-side
  /// this is not a stored column but "the member who joined first"
  /// (`room_owner_id()`), which is what makes ownership pass to the longest-
  /// standing member on its own when the creator leaves.
  final String ownerId;

  final DateTime createdAt;

  /// The room chat's last message — what the list shows instead of a member
  /// count once anybody has said anything, and what sorts the list. Null while
  /// the chat is empty, and deleted messages don't count: the preview would be
  /// a blank line.
  final DateTime? lastMessageAt;
  final String? lastMessageText;
  final String? lastMessageAuthorId;

  /// The last message carried photos or videos. One bit rather than the
  /// attachments themselves: the row only has to say "a photo" instead of
  /// leaving a blank line where a caption would be, and what to write there
  /// is a matter of the reader's own language.
  final bool lastMessageHasMedia;

  /// Messages by other people since this viewer last read the room. Own
  /// messages never count — sending one is what produced it.
  final int unreadCount;

  /// This viewer has silenced this one room's pushes. Per member, not per
  /// room: the flag lives on their own `room_members` row, so muting a room
  /// is invisible to everyone else in it.
  ///
  /// Pushes only. [unreadCount] keeps counting and the badge keeps showing —
  /// silencing a room is not the same as no longer reading it.
  final bool notificationsMuted;

  /// Everyone in the room, the owner first (server-side `order by seq`).
  final List<RoomMember> members;

  factory Room.fromRow(Map<String, dynamic> row) => Room(
    id: row['id'] as String,
    name: row['name'] as String?,
    avatarPath: row['avatar_path'] as String?,
    isDirect: row['is_direct'] as bool,
    ownerId: row['owner_id'] as String,
    createdAt: parseTimestamp(row['created_at'] as String),
    lastMessageAt: row['last_message_at'] == null
        ? null
        : parseTimestamp(row['last_message_at'] as String),
    lastMessageText: row['last_message_text'] as String?,
    lastMessageAuthorId: row['last_message_author_id'] as String?,
    lastMessageHasMedia: row['last_message_has_media'] as bool? ?? false,
    unreadCount: (row['unread_count'] as num?)?.toInt() ?? 0,
    notificationsMuted: row['notifications_muted'] as bool? ?? false,
    members: [
      for (final member in (row['members'] as List<dynamic>? ?? const []))
        RoomMember.fromJson(member as Map<String, dynamic>),
    ],
  );

  /// The other people in the room — everyone but the viewer. The two-person
  /// room's single entry is what names it.
  List<RoomMember> othersThan(String? viewerId) => [
    for (final member in members)
      if (member.userId != viewerId) member,
  ];

  bool isOwnedBy(String? userId) => userId != null && ownerId == userId;

  /// The member with [userId], or null when they are no longer in the room —
  /// which is exactly what happens to the author of an old message after they
  /// leave, and why every caller has to handle the null.
  RoomMember? memberById(String? userId) {
    if (userId == null) return null;
    for (final member in members) {
      if (member.userId == userId) return member;
    }
    return null;
  }
}

/// One photo or video attached to a message.
///
/// Unlike a post's media this is not a row of its own but an element of
/// `room_messages.media` (migration 20260828120000). The reason is realtime:
/// a subscriber is handed the message ROW and nothing else, so attachments
/// living in a second table would arrive — if at all — a request later, and
/// everyone else's screen would show an empty bubble until then.
class RoomMessageMedia implements GalleryMedia {
  const RoomMessageMedia({
    required this.storagePath,
    required this.isVideo,
    this.posterPath,
    this.url,
    this.posterUrl,
  });

  @override
  final String storagePath;

  @override
  final String? posterPath;

  @override
  final bool isVideo;

  @override
  final String? url;

  @override
  final String? posterUrl;

  @override
  RoomMessageMedia withUrls({String? url, String? posterUrl}) =>
      RoomMessageMedia(
        storagePath: storagePath,
        posterPath: posterPath,
        isVideo: isVideo,
        url: url ?? this.url,
        posterUrl: posterUrl ?? this.posterUrl,
      );

  factory RoomMessageMedia.fromJson(Map<String, dynamic> json) =>
      RoomMessageMedia(
        storagePath: json['storage_path'] as String,
        posterPath: json['poster_path'] as String?,
        isVideo: json['media_type'] == 'video',
      );

  /// What goes into the row. The server checks this shape itself
  /// (`room_message_media_ok()`), including that every path sits under this
  /// room's and this author's own prefix.
  Map<String, dynamic> toJson() => {
    'media_type': isVideo ? 'video' : 'image',
    'storage_path': storagePath,
    if (posterPath != null) 'poster_path': posterPath,
  };
}

/// One chat message.
///
/// A deleted message keeps its row: [deletedAt] is set and [text] is emptied
/// server-side. It stays in the list as a tombstone rather than vanishing,
/// for the same reason a deleted comment does — and because realtime hands
/// out a DELETE event without the row's contents, so a tombstone arrives as
/// an ordinary UPDATE that RLS can still filter.
class RoomMessage {
  const RoomMessage({
    required this.id,
    required this.roomId,
    required this.authorId,
    required this.text,
    required this.createdAt,
    this.media = const [],
    this.authorName,
    this.deletedAt,
  });

  final String id;
  final String roomId;
  final String authorId;
  final String text;
  final DateTime createdAt;

  /// Up to 10 photos/videos, in the order they were picked. Empty for a
  /// text-only message, and always empty on a tombstone — deleting a message
  /// drops its attachments in the same statement that blanks its text.
  final List<RoomMessageMedia> media;

  /// Only ever set on a message read through [RoomsRepository.fetchMessages],
  /// which embeds it. A message arriving over realtime carries the raw row and
  /// no join, so the screen resolves the name from the room's member list.
  final String? authorName;

  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  factory RoomMessage.fromRow(Map<String, dynamic> row) => RoomMessage(
    id: row['id'] as String,
    roomId: row['room_id'] as String,
    authorId: row['author_id'] as String,
    text: row['text'] as String? ?? '',
    createdAt: parseTimestamp(row['created_at'] as String),
    media: [
      for (final item in (row['media'] as List<dynamic>? ?? const []))
        RoomMessageMedia.fromJson(item as Map<String, dynamic>),
    ],
    authorName: (row['author'] as Map<String, dynamic>?)?['name'] as String?,
    deletedAt: row['deleted_at'] == null
        ? null
        : parseTimestamp(row['deleted_at'] as String),
  );
}

/// What to call [room] on [viewerId]'s screen.
///
/// A named room is its name for everyone. An unnamed one is the list of its
/// other members, which is why the same room reads as "Аня" to me and as my
/// own name to Аня — the two-person case is not special-cased here, it just
/// falls out of "everyone except me".
///
/// [fallback] covers the room whose other members are all gone: a group can
/// briefly be down to one person before its last member leaves, and an empty
/// title is worse than a generic one.
String roomDisplayName(
  Room room,
  String? viewerId, {
  required String fallback,
}) {
  final name = room.name;
  if (name != null && name.isNotEmpty) return name;
  final others = room.othersThan(viewerId);
  if (others.isEmpty) return fallback;
  return others.map((member) => member.name).join(', ');
}

/// One member's read/delivered marks, as read straight off their
/// `room_members` row.
///
/// The chat screen never stores a per-message status — it compares each of
/// the viewer's own messages against these marks instead: read if the
/// mark is no older than the message, delivered the same way against
/// [lastDeliveredAt]. That is also why only a message's own author needs
/// this — nobody draws ticks on a message they received.
class RoomMemberReceipt {
  const RoomMemberReceipt({
    required this.userId,
    required this.lastReadAt,
    required this.lastDeliveredAt,
  });

  final String userId;
  final DateTime lastReadAt;
  final DateTime lastDeliveredAt;

  factory RoomMemberReceipt.fromRow(Map<String, dynamic> row) =>
      RoomMemberReceipt(
        userId: row['user_id'] as String,
        lastReadAt: parseTimestamp(row['last_read_at'] as String),
        lastDeliveredAt: parseTimestamp(row['last_delivered_at'] as String),
      );
}

/// Where a room's own picture lives: `rooms/<room_id>/<token>.<ext>`, one
/// folder per room the way `avatars/` and `posts/` use one per user. Both the
/// CHECK on `rooms.avatar_path` and the storage policies read the room id out
/// of this path, so its shape is load-bearing, not a convention.
String roomAvatarPath({
  required String roomId,
  required String token,
  required String ext,
}) => 'rooms/$roomId/$token.$ext';

/// Where one attachment of a message lives:
/// `messages/<room_id>/<author_id>/<send token>/<file token>.<ext>`.
///
/// Every segment is load-bearing, and by two independent readers: the storage
/// policies (a member of that room may read it, its author may write it) and
/// the CHECK on `room_messages.media`, which refuses a row whose paths sit
/// outside its own room and author. The send token groups one submission, the
/// file token names the item — minted once per pick, so a retry addresses the
/// same object instead of leaving a copy behind.
String roomMessageMediaPath({
  required String roomId,
  required String authorId,
  required String clientToken,
  required String mediaToken,
  required String ext,
}) => 'messages/$roomId/$authorId/$clientToken/$mediaToken.$ext';

/// Path of a video's poster frame — same prefix as its video, own file.
String roomMessagePosterPath({
  required String roomId,
  required String authorId,
  required String clientToken,
  required String mediaToken,
}) => 'messages/$roomId/$authorId/$clientToken/${mediaToken}_poster.jpg';

class RoomsRepository {
  RoomsRepository(this._client);

  final SupabaseClient _client;

  /// The whole room list in one round trip — name, membership (the list shows
  /// avatars) and last activity — instead of a query per room. See
  /// `my_rooms()`; it reads `users` from inside `security definer`, which is
  /// what lets it hand back names of room peers the viewer has no Connection
  /// with.
  Future<List<Room>> fetchRooms() async {
    final rows = await _client.rpc('my_rooms').timeout(networkTimeout);
    // Fire-and-forget: fetching the list is itself the only "delivered"
    // signal this app has (no push-delivery acks), and a failure here
    // shouldn't hold up showing the list itself.
    unawaited(markRoomsDelivered().catchError((_) {}));
    return [
      for (final row in (rows as List<dynamic>))
        Room.fromRow(row as Map<String, dynamic>),
    ];
  }

  /// Marks every room this device knows about as delivered as of now — see
  /// [RoomMemberReceipt]. Called on every [fetchRooms], since pulling the
  /// room list is the only moment this app can be sure the device is online
  /// and synced.
  Future<void> markRoomsDelivered() async {
    await _client.rpc('mark_rooms_delivered').timeout(networkTimeout);
  }

  /// Creates a room with [memberIds] (the caller is added server-side) and
  /// returns its id.
  ///
  /// With a single member this is the two-person room, and the call is
  /// idempotent: asking for a room with someone you already have one with
  /// hands back the existing room instead of a second copy of it. [name] is
  /// ignored in that case — a two-person room is named after the other person.
  Future<String> createRoom({
    required List<String> memberIds,
    String? name,
  }) async {
    final id = await _client
        .rpc(
          'create_room',
          params: {
            'p_member_ids': memberIds,
            'p_name': (name != null && name.isNotEmpty) ? name : null,
          },
        )
        .timeout(networkTimeout);
    return id as String;
  }

  /// Renames the room, or clears the name back to the member enumeration when
  /// [name] is null or empty. Owner only, and never a two-person room — both
  /// are refused server-side.
  Future<void> renameRoom({required String roomId, String? name}) async {
    await _client
        .rpc(
          'rename_room',
          params: {
            'p_room_id': roomId,
            'p_name': (name != null && name.isNotEmpty) ? name : null,
          },
        )
        .timeout(networkTimeout);
  }

  Future<void> addMember({
    required String roomId,
    required String userId,
  }) async {
    await _client
        .rpc(
          'add_room_member',
          params: {'p_room_id': roomId, 'p_user_id': userId},
        )
        .timeout(networkTimeout);
  }

  Future<void> removeMember({
    required String roomId,
    required String userId,
  }) async {
    await _client
        .rpc(
          'remove_room_member',
          params: {'p_room_id': roomId, 'p_user_id': userId},
        )
        .timeout(networkTimeout);
  }

  /// Uploads [file] as the room's picture and points the room at it.
  ///
  /// [token] is minted once per pick, not per attempt, so a retry addresses
  /// the same object instead of leaving a copy behind — same reasoning as
  /// `postMediaPath` and `profilePhotoPath`. The row is written first and the
  /// replaced object deleted after, because a room pointing at bytes that are
  /// gone is a hole every member sees, while bytes nothing points at are just
  /// bytes (see [deleteRowsThenObjects]).
  Future<void> setRoomAvatar({
    required String roomId,
    required File file,
    required String token,
    required String ext,
  }) async {
    final path = roomAvatarPath(roomId: roomId, token: token, ext: ext);
    await uploadTolerantFile(
      _client,
      bucket: mediaBucket,
      path: path,
      file: file,
    );
    await _replaceAvatarPath(roomId: roomId, path: path);
  }

  /// Drops the room's own picture; the list falls back to a member's avatar.
  Future<void> clearRoomAvatar(String roomId) =>
      _replaceAvatarPath(roomId: roomId, path: null);

  Future<void> _replaceAvatarPath({
    required String roomId,
    required String? path,
  }) async {
    String? orphaned;
    await deleteRowsThenObjects(
      rows: () async {
        orphaned =
            await _client
                    .rpc(
                      'set_room_avatar',
                      params: {'p_room_id': roomId, 'p_avatar_path': path},
                    )
                    .timeout(networkTimeout)
                as String?;
      },
      objects: () async {
        final stale = orphaned;
        if (stale == null) return;
        await _client.storage
            .from(mediaBucket)
            .remove([stale])
            .timeout(networkTimeout);
      },
    );
  }

  /// One page of a room's chat, newest first. [before] is the oldest message
  /// already on screen — the keyset cursor, same shape as the feed's.
  Future<List<RoomMessage>> fetchMessages({
    required String roomId,
    RoomMessage? before,
    int limit = 50,
  }) async {
    var query = _client
        .from('room_messages')
        .select('*, author:users(name)')
        .eq('room_id', roomId);
    if (before != null) {
      // Keyset, not offset: a message arriving while the user scrolls would
      // shift every offset by one and duplicate a row across pages.
      final at = before.createdAt.toUtc().toIso8601String();
      query = query.or(
        'created_at.lt.$at,and(created_at.eq.$at,id.lt.${before.id})',
      );
    }
    final rows = await query
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(limit)
        .timeout(networkTimeout);
    return [for (final row in rows) RoomMessage.fromRow(row)];
  }

  /// Sends a message. [clientToken] makes the send idempotent — a retry after
  /// a timeout that actually committed lands on the same unique index instead
  /// of saying the same thing twice.
  ///
  /// Returns the stored row: the screen needs the server's `created_at` (it
  /// orders the list) and the id, and cannot mint either itself.
  ///
  /// A plain insert with the duplicate handled afterwards, NOT an upsert, and
  /// that is not a style choice — an upsert here failed every single send,
  /// for two independent reasons:
  ///
  ///  * `on_conflict=author_id,client_token` asks Postgres to infer an index,
  ///    and the index behind it is partial (`where client_token is not null`).
  ///    Inference on a partial index only matches when the statement repeats
  ///    the index predicate, which PostgREST has no way to send — so the
  ///    server answered 42P10, "no unique or exclusion constraint matching the
  ///    ON CONFLICT specification". `posts` and `comments` get away with the
  ///    same idempotency trick because their indexes are not partial.
  ///  * even with a matching index, an upsert resolves to `DO UPDATE`, and
  ///    `room_messages` has neither an UPDATE grant nor an UPDATE policy on
  ///    purpose: editing a message is not a feature, and an UPDATE policy
  ///    cannot restrict *which* columns change — it would open `created_at`,
  ///    which is what unread counts are measured against.
  ///
  /// So the duplicate is answered where it actually shows up: 23505 from the
  /// unique index means this exact submission already landed, and the row it
  /// collided with is the answer the caller wanted.
  Future<RoomMessage> sendMessage({
    required String roomId,
    required String authorId,
    required String text,
    required String clientToken,
    List<PickedMedia> media = const [],
  }) async {
    const columns = '*, author:users(name)';
    // Files first, row second, exactly as the composer publishes a post: the
    // row is what everyone else's screen reacts to, so it must not name bytes
    // that are not there yet. A send that dies in between leaves objects
    // nothing points at — `reap_orphaned_media()` collects those, and since
    // 20260828120000 it knows the `messages/` prefix too.
    final items = <RoomMessageMedia>[];
    for (final item in media) {
      items.add(
        await _uploadMessageMedia(
          roomId: roomId,
          authorId: authorId,
          clientToken: clientToken,
          item: item,
        ),
      );
    }
    try {
      final row = await _client
          .from('room_messages')
          .insert({
            'room_id': roomId,
            'author_id': authorId,
            'text': text,
            'client_token': clientToken,
            'media': [for (final item in items) item.toJson()],
          })
          .select(columns)
          .single()
          .timeout(networkTimeout);
      return RoomMessage.fromRow(row);
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow;
      final row = await _client
          .from('room_messages')
          .select(columns)
          .eq('author_id', authorId)
          .eq('client_token', clientToken)
          .single()
          .timeout(networkTimeout);
      return RoomMessage.fromRow(row);
    }
  }

  /// Uploads one picked file and returns the attachment that will name it in
  /// the row.
  ///
  /// A video is uploaded from its path rather than its bytes (only the file
  /// being sent is ever resident), and its poster frame goes up as a second
  /// object under the same prefix.
  Future<RoomMessageMedia> _uploadMessageMedia({
    required String roomId,
    required String authorId,
    required String clientToken,
    required PickedMedia item,
  }) async {
    final path = roomMessageMediaPath(
      roomId: roomId,
      authorId: authorId,
      clientToken: clientToken,
      mediaToken: item.token,
      ext: item.ext,
    );
    if (item.isVideo) {
      final posterPath = roomMessagePosterPath(
        roomId: roomId,
        authorId: authorId,
        clientToken: clientToken,
        mediaToken: item.token,
      );
      await uploadTolerantFile(
        _client,
        bucket: mediaBucket,
        path: path,
        file: File(item.filePath!),
      );
      await uploadTolerant(
        _client,
        bucket: mediaBucket,
        path: posterPath,
        bytes: item.posterBytes!,
      );
      return RoomMessageMedia(
        storagePath: path,
        posterPath: posterPath,
        isVideo: true,
      );
    }
    await uploadTolerant(
      _client,
      bucket: mediaBucket,
      path: path,
      bytes: item.bytes!,
    );
    return RoomMessageMedia(storagePath: path, isVideo: false);
  }

  /// Signs attachment paths so they can be shown. Same call the feed makes
  /// for post media — one bucket, one TTL (see [resolveSignedUrls]).
  Future<Map<String, String>> resolveMediaUrls(List<String> storagePaths) =>
      resolveSignedUrls(_client, storagePaths);

  /// Tombstones own message. Server-side it clears the text AND the
  /// attachments in the same statement, so nothing is left to read back — and
  /// hands back the paths that nothing points at any more, which is why the
  /// objects go only after the row write has committed (see
  /// [deleteRowsThenObjects]): bytes nobody names are just bytes, a row
  /// naming bytes that are gone is a hole every member sees.
  Future<void> deleteMessage(String messageId) async {
    var orphaned = const <String>[];
    await deleteRowsThenObjects(
      rows: () async {
        final rows = await _client
            .rpc('delete_own_room_message', params: {'p_message_id': messageId})
            .timeout(networkTimeout);
        orphaned = [
          for (final row in (rows as List<dynamic>? ?? const []))
            (row as Map<String, dynamic>)['storage_path'] as String,
        ];
      },
      objects: () async {
        if (orphaned.isEmpty) return;
        await _client.storage
            .from(mediaBucket)
            .remove(orphaned)
            .timeout(networkTimeout);
      },
    );
  }

  /// Silences (or unsilences) this one room's pushes for this viewer.
  ///
  /// An RPC rather than a plain update, for the same reason [markRoomRead] is
  /// one: `room_members` has no UPDATE grant at all, and a policy that gave
  /// it one could not restrict *which* columns change — it would open
  /// `last_read_at` and `last_delivered_at`, the two marks unread counts and
  /// ticks are measured against.
  Future<void> setRoomMuted({
    required String roomId,
    required bool muted,
  }) async {
    await _client
        .rpc('set_room_muted', params: {'p_room_id': roomId, 'p_muted': muted})
        .timeout(networkTimeout);
  }

  /// Moves this viewer's read mark to now. Also what silences the room's push
  /// notifications while they are actually in the chat — the server skips a
  /// member whose mark is fresher than a minute.
  Future<void> markRoomRead(String roomId) async {
    await _client
        .rpc('mark_room_read', params: {'p_room_id': roomId})
        .timeout(networkTimeout);
  }

  /// Read/delivered marks for everyone in the room — what the chat screen
  /// compares each of the viewer's own messages against to draw its ticks.
  /// `room_members` is already readable by fellow members (the same policy
  /// that lets the room list show names and avatars), so this is a plain
  /// select, not an RPC.
  Future<List<RoomMemberReceipt>> fetchMemberReceipts(String roomId) async {
    final rows = await _client
        .from('room_members')
        .select('user_id, last_read_at, last_delivered_at')
        .eq('room_id', roomId)
        .timeout(networkTimeout);
    return [for (final row in rows) RoomMemberReceipt.fromRow(row)];
  }

  /// Live updates to [fetchMemberReceipts] — fires whenever any member's read
  /// or delivered mark moves, so a tick can flip while the sender is still
  /// looking at the screen. Same shape as [subscribeToMessages].
  void Function() subscribeToMemberReceipts({
    required String roomId,
    required void Function(RoomMemberReceipt receipt) onUpdate,
  }) {
    final filter = PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'room_id',
      value: roomId,
    );
    final channel = _client
        .channel('room_members_receipts:$roomId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'room_members',
          filter: filter,
          callback: (payload) =>
              onUpdate(RoomMemberReceipt.fromRow(payload.newRecord)),
        )
        .subscribe();
    return () => channel.unsubscribe();
  }

  /// Live messages for one room. Returns the unsubscribe callback — the caller
  /// must call it when the screen goes away, or the channel outlives it and
  /// its callbacks fire into a dead widget.
  ///
  /// A callback rather than the channel itself: the screen has no other reason
  /// to know that Supabase Realtime exists, and a test can hand back a no-op
  /// instead of building a socket.
  ///
  /// Inserts and updates both matter: an update is how a delete arrives (see
  /// [RoomMessage]). The server-side filter is on `room_id`, and RLS is
  /// applied on top of it per subscriber, so another room's traffic cannot
  /// reach this channel even if the filter were wrong.
  void Function() subscribeToMessages({
    required String roomId,
    required void Function(RoomMessage message) onInsert,
    required void Function(RoomMessage message) onUpdate,
  }) {
    final filter = PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'room_id',
      value: roomId,
    );
    final channel = _client
        .channel('room_messages:$roomId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'room_messages',
          filter: filter,
          callback: (payload) =>
              onInsert(RoomMessage.fromRow(payload.newRecord)),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'room_messages',
          filter: filter,
          callback: (payload) =>
              onUpdate(RoomMessage.fromRow(payload.newRecord)),
        )
        .subscribe();
    return () => channel.unsubscribe();
  }

  /// Leaves the room. This can end the room: a two-person room always goes
  /// (it is the pair), and a group room goes when its last member leaves.
  /// Otherwise ownership simply moves on to the next longest-standing member.
  Future<void> leaveRoom(String roomId) async {
    await _client
        .rpc('leave_room', params: {'p_room_id': roomId})
        .timeout(networkTimeout);
  }
}

final roomsRepositoryProvider = Provider<RoomsRepository>((ref) {
  return RoomsRepository(ref.watch(supabaseClientProvider));
});

/// The viewer's rooms, newest activity first.
///
/// Not autoDispose: the composer reads it to offer its destination
/// checkboxes, and the rooms tab keeps its state in the shell's IndexedStack —
/// an autoDispose provider would refetch the list on every visit to either.
/// [roomsRefreshTickProvider] is what makes it reload when something actually
/// changed it.
final myRoomsProvider = FutureProvider<List<Room>>((ref) {
  ref.watch(roomsRefreshTickProvider);
  return ref.watch(roomsRepositoryProvider).fetchRooms();
});

/// One room out of [myRoomsProvider], or null while the list is still loading
/// (or once the room is gone — left, or emptied by its last member leaving).
///
/// Room screens watch this rather than holding the [Room] they were opened
/// with: a rename, an added member or a departure has to show up on a screen
/// that is already open, and the list is refetched as a whole anyway.
final roomProvider = Provider.family<Room?, String>((ref, roomId) {
  final rooms = ref.watch(myRoomsProvider).value;
  if (rooms == null) return null;
  for (final room in rooms) {
    if (room.id == roomId) return room;
  }
  return null;
});

/// Bumped whenever the room list stops matching the server: a room created,
/// renamed, left, or a post published into one (which reorders the list by
/// last activity). Same shape and same reason as `feedRefreshTickProvider`.
class RoomsRefreshTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final roomsRefreshTickProvider = NotifierProvider<RoomsRefreshTick, int>(
  RoomsRefreshTick.new,
);
