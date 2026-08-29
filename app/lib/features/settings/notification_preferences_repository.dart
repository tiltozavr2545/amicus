import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/network_timeout.dart';
import '../auth/auth_providers.dart';

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

  /// Upserts the whole row — six booleans is little enough that writing all
  /// of them on every toggle is simpler than tracking which one column
  /// changed, and it's what creates the row on a user's first-ever toggle.
  Future<void> save(String userId, NotificationPreferences prefs) {
    return _client
        .from('notification_preferences')
        .upsert({
          'user_id': userId,
          'notify_system_account': prefs.systemAccount,
          'notify_favorites': prefs.favorites,
          'notify_comments': prefs.comments,
          'notify_digest': prefs.digest,
          'notify_inactive_week': prefs.inactiveWeek,
          'notify_room_messages': prefs.roomMessages,
        })
        .timeout(networkTimeout);
  }
}

final notificationPreferencesRepositoryProvider =
    Provider<NotificationPreferencesRepository>((ref) {
      return NotificationPreferencesRepository(
        ref.watch(supabaseClientProvider),
      );
    });
