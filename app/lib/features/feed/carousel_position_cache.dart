import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How many posts' positions are kept before the least recently touched ones
/// are dropped. A long scrolling session would otherwise grow this map for
/// every multi-photo post ever built; a few hundred entries covers "scroll
/// down a screenful or two, then back up" — what this cache exists for —
/// while staying a few kilobytes.
const _capacity = 200;

/// Remembers which slide of a post's carousel the viewer left off on, so
/// scrolling a post out of the feed and back doesn't snap it to photo 1.
///
/// Deliberately in memory only, not [SharedPreferences]: leaving a post on
/// photo 3 is context for *this* pass through the feed, and a viewer who
/// closes the app expects to come back to the top of every post. Riverpod
/// keeps this alive exactly as long as the app process, which is the wanted
/// lifetime.
///
/// A [PageStorageKey] on the carousel would have covered scrolling within one
/// list, but not the feed and a profile's post list showing the same post, and
/// it restores a pixel offset rather than an index — this list also has to
/// survive the media being edited under it (see `_MediaCarousel`, which
/// clamps).
class CarouselPositionCache {
  /// A plain map is insertion-ordered in Dart, and entries are re-inserted on
  /// every read, so the first key is always the least recently used one.
  final _positions = <String, int>{};

  /// The slide [postId] was last left on, or null if this post hasn't been
  /// swiped in this session.
  int? read(String postId) {
    final index = _positions.remove(postId);
    if (index != null) _positions[postId] = index;
    return index;
  }

  void write(String postId, int index) {
    _positions
      ..remove(postId)
      ..[postId] = index;
    while (_positions.length > _capacity) {
      _positions.remove(_positions.keys.first);
    }
  }

  /// Dropped on sign-out along with the rest of the previous account's feed
  /// state: these are post ids the next account may not be allowed to see.
  void clear() => _positions.clear();
}

final carouselPositionCacheProvider = Provider<CarouselPositionCache>(
  (ref) => CarouselPositionCache(),
);
