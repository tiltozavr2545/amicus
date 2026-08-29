import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'feed_repository.dart';

const _keyPrefix = 'feed_cache_';

/// Persists a snapshot of the most recently loaded first page of one feed
/// scope — `scope` mirrors what `PostListView` is showing: null for the main
/// feed, an author's id for their posts — so the screen has something to show
/// before the network round trip finishes, or at all if there's no
/// connection. Deliberately only the first page: this is "don't be blank
/// without a network", not offline pagination.
///
/// There was briefly a third scope, `room_<id>`, for a room's own feed. Rooms
/// stopped having feeds in 20260828100000 and no caller mints that key any
/// more; [clear] still matches on the prefix alone, so any entry left on a
/// device from back then is wiped along with the rest.
///
/// Every entry is scoped to the *viewer* as well as the feed scope, and
/// [clear] wipes the lot on sign-out. Both are load-bearing, for the same
/// reason and independently: a cached page holds posts, author names and
/// signed media URLs that RLS only ever showed to the account that fetched
/// them. Keyed by scope alone (as it was until this was fixed), the next
/// account to sign in on the same device read the previous account's feed
/// straight off disk — and kept showing it indefinitely while offline, since
/// [PostListView] deliberately falls back to the cache when a fetch fails.
/// The key scoping is what holds if [clear] never runs (crash, force-stop,
/// a sign-out that failed); [clear] is what stops the bytes lingering on
/// disk after the account is gone.
class FeedCache {
  const FeedCache();

  /// [userId] is the *viewer*, [scope] the feed scope. A null [userId]
  /// (no session) gets its own slot rather than sharing the signed-out one
  /// with whoever was here last.
  String _key(String? userId, String? scope) =>
      '$_keyPrefix${userId ?? 'anon'}_${scope ?? 'main'}';

  /// Null means "nothing usable here" — for every reason, including the read
  /// itself failing.
  ///
  /// The guard covers `getInstance()` as well as the decode, and that is the
  /// half that was missing. This future is awaited in two places
  /// ([PostListView._primeFromCache] and, crucially, inside `_loadMore`'s own
  /// `catch`), so a rejection did two things at once: it was an unhandled
  /// async error out of the prime, and in the catch it threw *before* the line
  /// that assigns `_errorMessage`. A first cold start with no connection then
  /// showed "no posts yet" — the opposite of what had happened — instead of
  /// "failed to load feed". A cache that cannot be read is not an error worth
  /// surfacing on its own: it is exactly the "no cache" case.
  Future<List<Post>?> load(String? userId, String? scope) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(userId, scope));
      if (raw == null) return null;
      final rows = jsonDecode(raw) as List<dynamic>;
      return rows
          .map((row) => Post.fromCacheJson(row as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Cached shape from an older app version, corrupted JSON, or the
      // preferences store itself unavailable — treat all of it as "no cache"
      // rather than crashing the feed over a stale snapshot.
      return null;
    }
  }

  Future<void> save(String? userId, String? scope, List<Post> posts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(userId, scope),
      jsonEncode(posts.map((p) => p.toCacheJson()).toList()),
    );
  }

  /// Drops every cached page, for every viewer and every scope. Called on
  /// sign-out and account deletion — including the entries written under the
  /// unscoped keys this class used before scoping existed, which is why it
  /// matches on the prefix rather than reconstructing one user's keys.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    final stale = prefs.getKeys().where((k) => k.startsWith(_keyPrefix));
    for (final key in stale) {
      await prefs.remove(key);
    }
  }
}

final feedCacheProvider = Provider<FeedCache>((ref) => const FeedCache());
