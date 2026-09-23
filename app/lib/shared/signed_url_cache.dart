import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'signed_urls.dart';

/// How many paths keep their signature before the oldest are dropped.
///
/// One chat message carries at most ten attachments, so this covers roughly
/// fifty messages' worth of photos — far more than fits on a screen, which is
/// what the cache is for. Each entry is a path, a URL and a timestamp: a few
/// hundred bytes, so the whole map stays well under a megabyte.
const _capacity = 512;

/// How long before a signature actually lapses this cache stops handing it
/// out.
///
/// A URL good for another thirty seconds is technically valid and practically
/// useless: it has to survive being handed to `CachedNetworkImage`, a layout
/// pass and an HTTP round trip on a bad connection. Five minutes is the
/// difference between "still signed" and "still usable".
const _expiryMargin = Duration(minutes: 5);

class _Entry {
  const _Entry(this.url, this.usableUntil);

  final String url;
  final DateTime usableUntil;
}

/// Signed URLs for objects in the private `media` bucket, kept for as long as
/// they are good for.
///
/// The `media` bucket is private, so a storage path is not displayable until
/// it has been signed, and signing is a network round trip. That round trip
/// being **asynchronous** is the whole problem this class exists for: a
/// widget that signs its own paths in `initState` has nothing to show until
/// the answer comes back, so it shows a spinner — and it does that again
/// every single time its `State` is recreated, however briefly the thing was
/// gone.
///
/// In the room chat that is not a rare event but the normal one. The message
/// list inserts a new message at index 0, every index below it shifts, and
/// `ScrollablePositionedList` builds through a `SliverChildBuilderDelegate`
/// with no `findChildIndexCallback` to offer (the package does not expose
/// one), so the element sitting in a given slot is simply handed the *next*
/// message. The keyed attachment widget inside it can't match, its `State`
/// goes, and a photo that had been on screen for ten minutes blinks back to a
/// spinner and re-signs itself — once per visible bubble, on every message
/// sent or received.
///
/// A cache fixes that at the root rather than fighting the list: the
/// recreated `State` asks [read] *synchronously*, before its first frame, and
/// gets the URL it had a moment ago. `CachedNetworkImage` then paints from
/// its own disk cache (keyed on the storage path, not on the query string —
/// see `_Thumbnail`) and nothing blinks, nothing is re-signed, and no request
/// is made.
///
/// In memory only, and deliberately: these are URLs to objects RLS showed to
/// *this* account, and they are worthless after [signedUrlTtl] anyway.
/// Riverpod keeps it alive exactly as long as the app process, and
/// `AccountRepository` [clear]s it on sign-out along with the rest of the
/// previous account's state.
class SignedUrlCache {
  /// A plain map is insertion-ordered in Dart, so the first key is always the
  /// longest-ago signed one — which, since every entry gets the same TTL, is
  /// also the one closest to lapsing. Evicting from the front therefore drops
  /// what was about to become useless anyway.
  final _entries = <String, _Entry>{};

  /// Injectable so a test can move time without waiting for it.
  final DateTime Function() _now;

  SignedUrlCache({DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The URLs already held for [storagePaths], by path. Paths with no entry —
  /// never signed, or signed long enough ago to have lapsed — are simply
  /// absent, which is the same shape [resolveSignedUrls] answers in, so the
  /// two are interchangeable at the call site.
  Map<String, String> read(Iterable<String> storagePaths) {
    final now = _now();
    final hits = <String, String>{};
    for (final path in storagePaths) {
      final entry = _entries[path];
      if (entry == null) continue;
      if (!entry.usableUntil.isAfter(now)) {
        // Dropped rather than left to the capacity sweep: a lapsed entry that
        // stays in the map would keep answering "miss" at the cost of a
        // lookup, and holding a URL nobody may use is not a cache.
        _entries.remove(path);
        continue;
      }
      hits[path] = entry.url;
    }
    return hits;
  }

  /// Records what [resolveSignedUrls] just handed back. Keyed by path, so
  /// re-signing a path replaces its entry and moves it to the back of the
  /// eviction order, where a fresh signature belongs.
  void write(Map<String, String> signedByPath) {
    if (signedByPath.isEmpty) return;
    final usableUntil = _now()
        .add(const Duration(seconds: signedUrlTtl))
        .subtract(_expiryMargin);
    for (final MapEntry(key: path, value: url) in signedByPath.entries) {
      _entries
        ..remove(path)
        ..[path] = _Entry(url, usableUntil);
    }
    while (_entries.length > _capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Dropped on sign-out: every URL in here was signed for the account that
  /// is leaving, and the next one may not be allowed to see the object behind
  /// it.
  void clear() => _entries.clear();
}

final signedUrlCacheProvider = Provider<SignedUrlCache>(
  (ref) => SignedUrlCache(),
);
