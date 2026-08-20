import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/network_timeout.dart';
import '../auth/auth_providers.dart';
import '../feed/carousel_position_cache.dart';
import '../feed/feed_cache.dart';
import '../notifications/push_notifications_repository.dart';

const _bucket = 'media';

class AccountRepository {
  AccountRepository(
    this._client,
    this._pushRepository,
    this._feedCache,
    this._carouselPositions,
  );

  final SupabaseClient _client;
  final PushNotificationsRepository _pushRepository;
  final FeedCache _feedCache;
  final CarouselPositionCache _carouselPositions;

  /// Drops this device's push token (best-effort, while the session is still
  /// valid — see [PushNotificationsRepository.unregisterDevice]), wipes the
  /// on-disk feed cache, and signs out.
  ///
  /// The cache wipe is not best-effort housekeeping: a cached page holds
  /// posts, author names and signed media URLs that RLS only ever showed to
  /// *this* account, and it outlives the session on disk. It is awaited
  /// before `signOut()` so the next account can never race a read against
  /// it — [FeedCache]'s per-user keys are the second line of defence for
  /// when this never runs at all.
  Future<void> signOut(String userId) async {
    try {
      await _pushRepository.unregisterDevice(userId: userId);
    } catch (_) {
      // Best-effort: a network hiccup here shouldn't block sign-out.
    }
    await _feedCache.clear();
    _carouselPositions.clear();
    await _client.auth.signOut();
  }

  /// Permanently deletes the current user's account.
  ///
  /// Storage isn't reachable from the DB-side FK cascade that
  /// `delete_own_account()` relies on for everything else (see that
  /// migration), so this user's profile photos and post media are removed
  /// here first, best-effort — a leftover object becomes unreachable the
  /// moment the RPC below commits (its visibility policies all require
  /// rows — `connections`, `users` — that no longer exist), not a real leak,
  /// so a failed cleanup here must not block the deletion itself.
  ///
  /// The gallery is enumerated from `profile_photos`, not from
  /// `users.avatar_path`: that column names only the *top* photo (position 0,
  /// kept in sync by a trigger), so reading it alone left the other up-to-79
  /// objects behind — the same orphaning migration 20260820100000 had to be
  /// written to undo, which is why the union of both is collected here (a
  /// legacy avatar predating `profile_photos` has no row of its own).
  Future<void> deleteAccount(String userId) async {
    try {
      await _pushRepository.unregisterDevice(userId: userId);
    } catch (_) {
      // Best-effort, same as signOut above.
    }

    try {
      final paths = <String>{};

      final profileRow = await _client
          .from('users')
          .select('avatar_path')
          .eq('id', userId)
          .single()
          .timeout(networkTimeout);
      final avatarPath = profileRow['avatar_path'] as String?;
      if (avatarPath != null) paths.add(avatarPath);

      final photoRows = await _client
          .from('profile_photos')
          .select('storage_path')
          .eq('user_id', userId)
          .timeout(networkTimeout);
      for (final row in photoRows) {
        paths.add(row['storage_path'] as String);
      }

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
            .remove(paths.toList())
            .timeout(networkTimeout);
      }
    } catch (_) {
      // Best-effort cleanup, see the doc comment above.
    }

    await _client.rpc('delete_own_account').timeout(networkTimeout);

    // Not best-effort, and not conditional on the cleanup above: the cached
    // pages are this account's content sitting in plain SharedPreferences,
    // and the account it belonged to no longer exists to re-authorize them.
    await _feedCache.clear();
    _carouselPositions.clear();

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
    ref.watch(feedCacheProvider),
    ref.watch(carouselPositionCacheProvider),
  );
});
