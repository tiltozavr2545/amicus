import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/network_timeout.dart';
import '../../shared/parse_timestamp.dart';
import '../auth/auth_providers.dart';

class ActivatedConnection {
  const ActivatedConnection({required this.ownerId, required this.ownerName});

  final String ownerId;
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

class BlockedUser {
  const BlockedUser({
    required this.userId,
    required this.name,
    required this.blockedAt,
    this.avatarPath,
  });

  final String userId;
  final String name;
  final DateTime blockedAt;
  final String? avatarPath;
}

class ConnectionsRepository {
  ConnectionsRepository(this._client);

  final SupabaseClient _client;

  Future<String> createInviteLink() async {
    final code = await _client
        .rpc('create_invite_link')
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
    return ActivatedConnection(
      ownerId: row['owner_id'] as String,
      ownerName: row['owner_name'] as String,
    );
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
        .select(
          'blocked_id, created_at, '
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
        blockedAt: parseTimestamp(row['created_at'] as String),
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
