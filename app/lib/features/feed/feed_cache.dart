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
class FeedCache {
  const FeedCache();

  String _key(String? authorId) => '$_keyPrefix${authorId ?? 'main'}';

  Future<List<Post>?> load(String? authorId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(authorId));
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

  Future<void> save(String? authorId, List<Post> posts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(authorId),
      jsonEncode(posts.map((p) => p.toCacheJson()).toList()),
    );
  }
}

final feedCacheProvider = Provider<FeedCache>((ref) => const FeedCache());
