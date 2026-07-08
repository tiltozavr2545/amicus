import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';

class ActivatedConnection {
  const ActivatedConnection({required this.ownerId, required this.ownerName});

  final String ownerId;
  final String ownerName;
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
    final row = rows.first as Map<String, dynamic>;
    return ActivatedConnection(
      ownerId: row['owner_id'] as String,
      ownerName: row['owner_name'] as String,
    );
  }
}

final connectionsRepositoryProvider = Provider<ConnectionsRepository>((ref) {
  return ConnectionsRepository(ref.watch(supabaseClientProvider));
});
