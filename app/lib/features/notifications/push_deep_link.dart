import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where a tapped notification should land.
///
/// Parsed from the `data` map `send-push` attaches to every message — the
/// outbox payload has carried these ids since rooms landed, but until
/// 20260828 they stopped at the Edge Function, which sent `notification`
/// alone. A push that opens the app on whatever screen it was last on is a
/// push that made the user hunt for what it was about.
sealed class PushTarget {
  const PushTarget();
}

/// A message arrived in this room: open its chat.
class RoomChatTarget extends PushTarget {
  const RoomChatTarget(this.roomId);
  final String roomId;
}

/// Somebody commented on a post, or replied to a comment: open the post's
/// comments, which is where both of those live.
class PostCommentsTarget extends PushTarget {
  const PostCommentsTarget(this.postId);
  final String postId;
}

/// Somebody asked to be a connection, or answered such an ask: open the
/// Connections screen, which is where both are handled.
class ConnectionsTarget extends PushTarget {
  const ConnectionsTarget();
}

/// Nothing more specific than "there is something new in the feed" — a new
/// post from a favourite, a digest, a nudge after a quiet week. The feed is
/// the answer to all three, and it is also the tab the app opens on, so this
/// only matters when the app was left on another one.
class FeedTarget extends PushTarget {
  const FeedTarget();
}

/// What [data] points at, or null when the notification has no destination
/// worth taking anyone to (an update notice: the app is not where one
/// updates it).
///
/// A pure function so the whole table can be unit-tested without Firebase:
/// every kind the outbox can hold decides here, once.
PushTarget? pushTargetFrom(Map<String, dynamic> data) {
  final roomId = data['room_id'] as String?;
  final postId = data['post_id'] as String?;
  return switch (data['kind']) {
    'room_message' when roomId != null => RoomChatTarget(roomId),
    'post_comment' ||
    'comment_reply' when postId != null => PostCommentsTarget(postId),
    'connection_request' || 'connection_accepted' => const ConnectionsTarget(),
    'new_post' || 'digest' || 'inactive_week' => const FeedTarget(),
    // Includes 'app_update'/'app_update_important' — and anything a future
    // migration adds before this table hears about it. Opening the app is
    // all such a push ever asked for.
    _ => null,
  };
}

/// Notifications the user has actually tapped, oldest first.
///
/// Two sources, because Android has two cases and only one of them is a
/// stream: an app resumed from the background gets `onMessageOpenedApp`, an
/// app started by the tap gets `getInitialMessage()` — once, and only if
/// nobody has asked for it yet. Both are joined here so the listener has one
/// thing to watch.
///
/// Not autoDispose: the shell watches it for the whole session, and a
/// rebuild that dropped and recreated it would ask `getInitialMessage()`
/// again and re-open the same screen.
final pushTapsProvider = StreamProvider<PushTarget>((ref) async* {
  final initial = await FirebaseMessaging.instance.getInitialMessage();
  if (initial != null) {
    final target = pushTargetFrom(initial.data);
    if (target != null) yield target;
  }
  yield* FirebaseMessaging.onMessageOpenedApp
      .map((message) => pushTargetFrom(message.data))
      .where((target) => target != null)
      .cast<PushTarget>();
});
