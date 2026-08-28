import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/network_timeout.dart';
import '../../shared/parse_timestamp.dart';
import '../auth/auth_providers.dart';

/// Who the caller just became a Connection with — the only thing the screen
/// needs in order to say so. `activate_invite_link()` also returns the
/// owner's id; reading it back out bound this model to a column nothing
/// displays, and made the parse fail on a shape change that could not
/// otherwise have mattered.
class ActivatedConnection {
  const ActivatedConnection({required this.ownerName});

  final String ownerName;
}

class Friend {
  const Friend({
    required this.userId,
    required this.name,
    required this.connectedAt,
    this.avatarPath,
    this.isMuted = false,
    this.isBlocked = false,
    this.isFavorite = false,
  });

  final String userId;
  final String name;
  final DateTime connectedAt;
  final String? avatarPath;
  final bool isMuted;
  final bool isBlocked;

  /// Favorited connections always push a notification on a new post, instead
  /// of only counting toward the "6+ posts" digest. Purely personal — the
  /// other side never knows or is affected.
  final bool isFavorite;
}

/// A user the caller has blocked, as the "Blocked users" screen shows them.
///
/// No `blockedAt`: the list is ordered newest-first server-side and the screen
/// renders avatar, name and an Unblock button. The field existed, was parsed
/// through `parseTimestamp` for every row, and was never read — if the date
/// is ever worth showing, it belongs next to `formatConnectionSummary`, which
/// already does this for the Connections list.
class BlockedUser {
  const BlockedUser({
    required this.userId,
    required this.name,
    this.avatarPath,
  });

  final String userId;
  final String name;
  final String? avatarPath;
}

/// A pending "let's be connections" ask, in whichever direction.
///
/// Only ever about someone the viewer shares a room with — that is the one
/// door this feature opens, and the server holds it (`request_connection()`
/// refuses anyone else). There is no people search here and none is implied.
class ConnectionRequest {
  const ConnectionRequest({
    required this.id,
    required this.otherId,
    required this.otherName,
    required this.isIncoming,
    this.otherAvatarPath,
  });

  final String id;

  /// The other side, whichever of the two columns they sit in — the screen
  /// shows one person either way, and [isIncoming] is what changes what it
  /// offers to do about them.
  final String otherId;
  final String otherName;
  final String? otherAvatarPath;

  /// They asked us. The other direction is shown too, as "asked" next to
  /// their name, so nobody asks twice into a silence.
  final bool isIncoming;

  factory ConnectionRequest.fromRow(Map<String, dynamic> row, String viewerId) {
    final isIncoming = row['recipient_id'] == viewerId;
    final other =
        (isIncoming ? row['requester'] : row['recipient'])
            as Map<String, dynamic>;
    return ConnectionRequest(
      id: row['id'] as String,
      otherId:
          (isIncoming ? row['requester_id'] : row['recipient_id']) as String,
      otherName: other['name'] as String,
      otherAvatarPath: other['avatar_path'] as String?,
      isIncoming: isIncoming,
    );
  }
}

class ConnectionsRepository {
  ConnectionsRepository(this._client);

  final SupabaseClient _client;

  /// Returns the caller's current unused invite code, minting one if they have
  /// none. Idempotent by design — a retry after a timeout must not leave two
  /// live codes — so calling it again on someone who already has a code hands
  /// back the same string. To *replace* a code, see [rotateInviteLink].
  Future<String> createInviteLink() async {
    final code = await _client
        .rpc('create_invite_link')
        .timeout(networkTimeout);
    return code as String;
  }

  /// Revokes the caller's current unused invite code and returns a fresh one.
  ///
  /// The separate RPC is the point: an invite code is a bearer secret — anyone
  /// holding it becomes a Connection with full feed, profile and gallery
  /// visibility — and [createInviteLink] deliberately cannot replace one, so
  /// until this existed a code sent to the wrong person stayed live until
  /// somebody redeemed it. The old row is deleted rather than marked used, so
  /// the revoked code reads as `PT404` ("no such code") rather than `PT409`
  /// ("already used"), which would be untrue. See migration 20260822150000.
  Future<String> rotateInviteLink() async {
    final code = await _client
        .rpc('rotate_invite_link')
        .timeout(networkTimeout);
    return code as String;
  }

  Future<ActivatedConnection> activateInviteLink(String code) async {
    final rows =
        await _client
                .rpc('activate_invite_link', params: {'p_code': code})
                .timeout(networkTimeout)
            as List<dynamic>;
    // The function returns the inviter's row; an empty result would mean the
    // owner profile vanished. Fail with a clear error instead of a raw
    // "Bad state: No element" from `.first`.
    if (rows.isEmpty) {
      throw StateError('activate_invite_link returned no inviter row');
    }
    final row = rows.first as Map<String, dynamic>;
    return ActivatedConnection(ownerName: row['owner_name'] as String);
  }

  Future<List<Friend>> fetchFriends(String currentUserId) async {
    // All four queries are independent, so they go out together rather than
    // costing this screen three extra serial round trips — the same reasoning
    // (and the same `Future.wait`) FeedRepository.fetchPage applies to its two
    // RPCs. This runs again on every ref.invalidate(friendsProvider), i.e.
    // after each mute/block/favorite tap.
    final (rows, mutedIds, blockedIds, favoriteIds) = await (
      _client
          .from('connections')
          .select(
            'user_a_id, user_b_id, created_at, '
            'user_a:users!connections_user_a_id_fkey(name, avatar_path), '
            'user_b:users!connections_user_b_id_fkey(name, avatar_path)',
          )
          .or('user_a_id.eq.$currentUserId,user_b_id.eq.$currentUserId')
          .order('created_at', ascending: false)
          .timeout(networkTimeout),
      _fetchIdSet(
        table: 'muted_users',
        ownerColumn: 'muter_id',
        otherColumn: 'muted_id',
        ownerId: currentUserId,
      ),
      _fetchIdSet(
        table: 'blocked_users',
        ownerColumn: 'blocker_id',
        otherColumn: 'blocked_id',
        ownerId: currentUserId,
      ),
      _fetchIdSet(
        table: 'favorite_users',
        ownerColumn: 'user_id',
        otherColumn: 'favorite_id',
        ownerId: currentUserId,
      ),
    ).wait;

    return rows.map((row) {
      final isCurrentUserA = row['user_a_id'] == currentUserId;
      final otherId = isCurrentUserA
          ? row['user_b_id'] as String
          : row['user_a_id'] as String;
      final other =
          (isCurrentUserA ? row['user_b'] : row['user_a'])
              as Map<String, dynamic>;
      return Friend(
        userId: otherId,
        name: other['name'] as String,
        connectedAt: parseTimestamp(row['created_at'] as String),
        avatarPath: other['avatar_path'] as String?,
        isMuted: mutedIds.contains(otherId),
        isBlocked: blockedIds.contains(otherId),
        isFavorite: favoriteIds.contains(otherId),
      );
    }).toList();
  }

  /// Every request this viewer is a side of, still waiting for an answer.
  ///
  /// A plain select: the RLS policy already scopes the table to the two
  /// people a row is about, so there is nothing an RPC would add — and the
  /// names come through the same embed the rest of the app uses, readable
  /// because sharing a room is enough to see someone's profile.
  Future<List<ConnectionRequest>> fetchPendingRequests(String viewerId) async {
    final rows = await _client
        .from('connection_requests')
        .select(
          'id, requester_id, recipient_id, '
          'requester:users!connection_requests_requester_id_fkey(name, avatar_path), '
          'recipient:users!connection_requests_recipient_id_fkey(name, avatar_path)',
        )
        .eq('status', 'pending')
        .order('created_at', ascending: false)
        .timeout(networkTimeout);
    return [for (final row in rows) ConnectionRequest.fromRow(row, viewerId)];
  }

  /// Asks [userId] to become a Connection. Returns whether that already
  /// settled it: two people who both asked are two people who both agreed, so
  /// the server connects them on the spot rather than staging a ceremony.
  ///
  /// Throws PostgrestException — PT403 when there is no shared room (or a
  /// block, deliberately answered the same way), PT409 when they are already
  /// connected or were already asked once.
  Future<bool> requestConnection(String userId) async {
    final result = await _client
        .rpc('request_connection', params: {'p_user_id': userId})
        .timeout(networkTimeout);
    return result == 'connected';
  }

  /// Accepts or declines an incoming request. A decline is silent by design:
  /// the other side simply never gets the button back.
  Future<void> respondToRequest({
    required String requestId,
    required bool accept,
  }) async {
    await _client
        .rpc(
          'respond_to_connection_request',
          params: {'p_request_id': requestId, 'p_accept': accept},
        )
        .timeout(networkTimeout);
  }

  Future<Set<String>> _fetchIdSet({
    required String table,
    required String ownerColumn,
    required String otherColumn,
    required String ownerId,
  }) async {
    final rows = await _client
        .from(table)
        .select(otherColumn)
        .eq(ownerColumn, ownerId)
        .timeout(networkTimeout);
    return rows.map((row) => row[otherColumn] as String).toSet();
  }

  Future<void> muteUser({required String muterId, required String mutedId}) {
    return _client
        .from('muted_users')
        .upsert({'muter_id': muterId, 'muted_id': mutedId})
        .timeout(networkTimeout);
  }

  Future<void> unmuteUser({required String muterId, required String mutedId}) {
    return _client
        .from('muted_users')
        .delete()
        .eq('muter_id', muterId)
        .eq('muted_id', mutedId)
        .timeout(networkTimeout);
  }

  Future<void> blockUser({
    required String blockerId,
    required String blockedId,
  }) {
    return _client
        .from('blocked_users')
        .upsert({'blocker_id': blockerId, 'blocked_id': blockedId})
        .timeout(networkTimeout);
  }

  Future<void> unblockUser({
    required String blockerId,
    required String blockedId,
  }) {
    return _client
        .from('blocked_users')
        .delete()
        .eq('blocker_id', blockerId)
        .eq('blocked_id', blockedId)
        .timeout(networkTimeout);
  }

  Future<void> favoriteUser({
    required String userId,
    required String favoriteId,
  }) {
    return _client
        .from('favorite_users')
        .upsert({'user_id': userId, 'favorite_id': favoriteId})
        .timeout(networkTimeout);
  }

  Future<void> unfavoriteUser({
    required String userId,
    required String favoriteId,
  }) {
    return _client
        .from('favorite_users')
        .delete()
        .eq('user_id', userId)
        .eq('favorite_id', favoriteId)
        .timeout(networkTimeout);
  }

  Future<List<BlockedUser>> fetchBlockedUsers(String currentUserId) async {
    final rows = await _client
        .from('blocked_users')
        // `created_at` is ordered on but not selected — PostgREST orders by
        // any column, and nothing on the screen shows the date.
        .select(
          'blocked_id, '
          'blocked:users!blocked_users_blocked_id_fkey(name, avatar_path)',
        )
        .eq('blocker_id', currentUserId)
        .order('created_at', ascending: false)
        .timeout(networkTimeout);

    return rows.map((row) {
      final blocked = row['blocked'] as Map<String, dynamic>;
      return BlockedUser(
        userId: row['blocked_id'] as String,
        name: blocked['name'] as String,
        avatarPath: blocked['avatar_path'] as String?,
      );
    }).toList();
  }
}

final connectionsRepositoryProvider = Provider<ConnectionsRepository>((ref) {
  return ConnectionsRepository(ref.watch(supabaseClientProvider));
});

/// The Connections list, with each friend's mute/block state.
///
/// Lives here rather than privately in `connections_screen.dart` because the
/// "Blocked users" screen has to invalidate it too: it opens as a route pushed
/// *over* ConnectionsScreen, which therefore stays mounted and keeps this
/// autoDispose provider alive with its cached, now-stale isBlocked flags.
final friendsProvider = FutureProvider.autoDispose<List<Friend>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  return ref.watch(connectionsRepositoryProvider).fetchFriends(userId!);
});

/// Pending connection requests in both directions, for the Connections screen
/// (which answers them) and the room screen (which must not offer to ask
/// twice).
///
/// Not autoDispose: the room screen and the Connections tab both read it, and
/// dropping it between them would refetch on every switch. [requestsRefreshTick]
/// is what makes it reload once something has actually changed it.
final pendingConnectionRequestsProvider =
    FutureProvider<List<ConnectionRequest>>((ref) {
      ref.watch(connectionRequestsTickProvider);
      final userId = ref.watch(currentUserIdProvider);
      if (userId == null) return Future.value(const []);
      return ref
          .watch(connectionsRepositoryProvider)
          .fetchPendingRequests(userId);
    });

/// Bumped whenever a request is sent or answered. Same shape and same reason
/// as `roomsRefreshTickProvider`.
class ConnectionRequestsTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final connectionRequestsTickProvider =
    NotifierProvider<ConnectionRequestsTick, int>(ConnectionRequestsTick.new);
