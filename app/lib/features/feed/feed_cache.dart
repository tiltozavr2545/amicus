import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'feed_repository.dart';

const _keyPrefix = 'feed_cache_';

/// Persists a snapshot of the most recently loaded first page of one feed
/// scope (the main feed, or one author's posts — `authorId` mirrors
/// `PostListView.authorId`: null for the main feed, an author's id for their
/// posts) so the screen has something to show before the network round trip
/// finishes, or at all if there's no connection. Deliberately only the first
/// page: this is "don't be blank without a network", not offline pagination.
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

  /// [userId] is the *viewer*, [authorId] the feed scope. A null [userId]
  /// (no session) gets its own slot rather than sharing the signed-out one
  /// with whoever was here last.
  String _key(String? userId, String? authorId) =>
      '$_keyPrefix${userId ?? 'anon'}_${authorId ?? 'main'}';

  Future<List<Post>?> load(String? userId, String? authorId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(userId, authorId));
    if (raw == null) return null;
    try {
      final rows = jsonDecode(raw) as List<dynamic>;
      return rows
          .map((row) => Post.fromCacheJson(row as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Cached shape from an older app version, or corrupted — treat it as
      // "no cache" rather than crashing the feed over a stale snapshot.
      return null;
    }
  }

  Future<void> save(String? userId, String? authorId, List<Post> posts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(userId, authorId),
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
