import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/network_timeout.dart';
import '../auth/auth_providers.dart';

enum NotificationPreference {
  systemAccount('notify_system_account'),
  favorites('notify_favorites'),
  comments('notify_comments'),
  digest('notify_digest'),
  inactiveWeek('notify_inactive_week'),
  roomMessages('notify_room_messages');

  const NotificationPreference(this.column);

  final String column;

  NotificationPreferences applyTo(NotificationPreferences prefs, bool value) =>
      switch (this) {
        systemAccount => prefs.copyWith(systemAccount: value),
        favorites => prefs.copyWith(favorites: value),
        comments => prefs.copyWith(comments: value),
        digest => prefs.copyWith(digest: value),
        inactiveWeek => prefs.copyWith(inactiveWeek: value),
        roomMessages => prefs.copyWith(roomMessages: value),
      };
}

/// One on/off switch per notification producer that already writes to
/// `notification_outbox` server-side (posts, favorites, comments/replies,
/// digest, inactivity nudge, and room messages) — see migrations
/// `20260819180000` and `20260826200000`. All default to on, matching how
/// every one of these already behaved before this screen existed.
///
/// Rooms briefly had two switches, the second for posts published into a
/// room. Room feeds were dropped whole in 20260828100000 and
/// `notify_room_posts` went with them: a switch that silences nothing is the
/// worst kind, because it is visible and it lies.
///
/// Not every kind has one. `app_update`/`app_update_important` and both
/// connection-request kinds are deliberately unswitchable — they are
/// addressed personally and arrive a few times a year, and "I will never
/// again find out that someone asked for me" is not a choice worth offering.
/// Muting one room is a separate thing again and lives on the member's own
/// `room_members` row (`set_room_muted()`), not here: this screen answers
/// "do I want pushes from chats at all", not "from this one".
class NotificationPreferences {
  const NotificationPreferences({
    this.systemAccount = true,
    this.favorites = true,
    this.comments = true,
    this.digest = true,
    this.inactiveWeek = true,
    this.roomMessages = true,
  });

  final bool systemAccount;
  final bool favorites;
  final bool comments;
  final bool digest;
  final bool inactiveWeek;
  final bool roomMessages;

  /// [row] is null when the user has never visited Settings — no row exists
  /// yet, and the server-side triggers read that same absence as "all on" via
  /// `coalesce(..., true)`, so the default here has to match.
  factory NotificationPreferences.fromRow(Map<String, dynamic>? row) {
    if (row == null) return const NotificationPreferences();
    return NotificationPreferences(
      systemAccount: row['notify_system_account'] as bool? ?? true,
      favorites: row['notify_favorites'] as bool? ?? true,
      comments: row['notify_comments'] as bool? ?? true,
      digest: row['notify_digest'] as bool? ?? true,
      inactiveWeek: row['notify_inactive_week'] as bool? ?? true,
      roomMessages: row['notify_room_messages'] as bool? ?? true,
    );
  }

  NotificationPreferences copyWith({
    bool? systemAccount,
    bool? favorites,
    bool? comments,
    bool? digest,
    bool? inactiveWeek,
    bool? roomMessages,
  }) => NotificationPreferences(
    systemAccount: systemAccount ?? this.systemAccount,
    favorites: favorites ?? this.favorites,
    comments: comments ?? this.comments,
    digest: digest ?? this.digest,
    inactiveWeek: inactiveWeek ?? this.inactiveWeek,
    roomMessages: roomMessages ?? this.roomMessages,
  );
}

class NotificationPreferencesRepository {
  NotificationPreferencesRepository(this._client);

  final SupabaseClient _client;

  Future<NotificationPreferences> fetch(String userId) async {
    final row = await _client
        .from('notification_preferences')
        .select()
        .eq('user_id', userId)
        .maybeSingle()
        .timeout(networkTimeout);
    return NotificationPreferences.fromRow(row);
  }

  /// Writes one switch and uses the database defaults on the first insert.
  Future<void> save(
    String userId,
    NotificationPreference preference,
    bool enabled,
  ) {
    return _client
        .from('notification_preferences')
        .upsert(
          {'user_id': userId, preference.column: enabled},
          onConflict: 'user_id',
          defaultToNull: false,
        )
        .timeout(networkTimeout);
  }
}

final notificationPreferencesRepositoryProvider =
    Provider<NotificationPreferencesRepository>((ref) {
      return NotificationPreferencesRepository(
        ref.watch(supabaseClientProvider),
      );
    });
