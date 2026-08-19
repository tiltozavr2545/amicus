import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/network_timeout.dart';
import '../auth/auth_providers.dart';
import '../notifications/push_notifications_repository.dart';

const _bucket = 'media';

class AccountRepository {
  AccountRepository(this._client, this._pushRepository);

  final SupabaseClient _client;
  final PushNotificationsRepository _pushRepository;

  /// Drops this device's push token (best-effort, while the session is still
  /// valid — see [PushNotificationsRepository.unregisterDevice]) and signs
  /// out.
  Future<void> signOut(String userId) async {
    try {
      await _pushRepository.unregisterDevice(userId: userId);
    } catch (_) {
      // Best-effort: a network hiccup here shouldn't block sign-out.
    }
    await _client.auth.signOut();
  }

  /// Permanently deletes the current user's account.
  ///
  /// Storage isn't reachable from the DB-side FK cascade that
  /// `delete_own_account()` relies on for everything else (see that
  /// migration), so the avatar and this user's post media are removed here
  /// first, best-effort — a leftover object becomes unreachable the moment
  /// the RPC below commits (its visibility policies all require rows —
  /// `connections`, `users` — that no longer exist), not a real leak, so a
  /// failed cleanup here must not block the deletion itself.
  Future<void> deleteAccount(String userId) async {
    try {
      await _pushRepository.unregisterDevice(userId: userId);
    } catch (_) {
      // Best-effort, same as signOut above.
    }

    try {
      final paths = <String>[];

      final profileRow = await _client
          .from('users')
          .select('avatar_path')
          .eq('id', userId)
          .single()
          .timeout(networkTimeout);
      final avatarPath = profileRow['avatar_path'] as String?;
      if (avatarPath != null) paths.add(avatarPath);

      final ownPosts = await _client
          .from('posts')
          .select('id')
          .eq('author_id', userId)
          .timeout(networkTimeout);
      final postIds = [for (final row in ownPosts) row['id'] as String];
      if (postIds.isNotEmpty) {
        final mediaRows = await _client
            .from('post_media')
            .select('storage_path, poster_path')
            .inFilter('post_id', postIds)
            .timeout(networkTimeout);
        for (final row in mediaRows) {
          paths.add(row['storage_path'] as String);
          final posterPath = row['poster_path'] as String?;
          if (posterPath != null) paths.add(posterPath);
        }
      }

      if (paths.isNotEmpty) {
        await _client.storage
            .from(_bucket)
            .remove(paths)
            .timeout(networkTimeout);
      }
    } catch (_) {
      // Best-effort cleanup, see the doc comment above.
    }

    await _client.rpc('delete_own_account').timeout(networkTimeout);

    // The account (and with it, every refresh token tied to this session) is
    // already gone server-side, so the default sign-out's revoke round-trip
    // has nothing left to revoke — local-only clears this device's session
    // without depending on that call succeeding.
    await _client.auth.signOut(scope: SignOutScope.local);
  }
}

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  return AccountRepository(
    ref.watch(supabaseClientProvider),
    ref.watch(pushNotificationsRepositoryProvider),
  );
});
