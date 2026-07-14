import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  });

  final String userId;
  final String name;
  final DateTime connectedAt;
  final String? avatarPath;
}

class ConnectionsRepository {
  ConnectionsRepository(this._client);

  final SupabaseClient _client;

  Future<String> createInviteLink() async {
    final code = await _client.rpc('create_invite_link');
    return code as String;
  }

  Future<ActivatedConnection> activateInviteLink(String code) async {
    final rows =
        await _client.rpc('activate_invite_link', params: {'p_code': code})
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
    final rows = await _client
        .from('connections')
        .select(
          'user_a_id, user_b_id, created_at, '
          'user_a:users!connections_user_a_id_fkey(name, avatar_path), '
          'user_b:users!connections_user_b_id_fkey(name, avatar_path)',
        )
        .or('user_a_id.eq.$currentUserId,user_b_id.eq.$currentUserId')
        .order('created_at', ascending: false);

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
        connectedAt: DateTime.parse(row['created_at'] as String),
        avatarPath: other['avatar_path'] as String?,
      );
    }).toList();
  }
}

final connectionsRepositoryProvider = Provider<ConnectionsRepository>((ref) {
  return ConnectionsRepository(ref.watch(supabaseClientProvider));
});
