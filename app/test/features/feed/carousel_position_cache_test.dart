import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/feed/carousel_position_cache.dart';

void main() {
  test('an unswiped post has no remembered slide', () {
    expect(CarouselPositionCache().read('p1'), isNull);
  });

  test('the last slide written for a post is the one read back', () {
    final cache = CarouselPositionCache()
      ..write('p1', 2)
      ..write('p1', 3)
      ..write('p2', 1);

    expect(cache.read('p1'), 3);
    expect(cache.read('p2'), 1);
  });

  test('sign-out drops every remembered slide', () {
    final cache = CarouselPositionCache()..write('p1', 2);
    cache.clear();

    expect(cache.read('p1'), isNull);
  });

  // A session that scrolls past thousands of posts must not grow this map
  // without bound — the oldest entries go, and reading one keeps it young.
  test('past the cap, the least recently used post is the one dropped', () {
    final cache = CarouselPositionCache();
    for (var i = 0; i < 200; i++) {
      cache.write('p$i', 1);
    }
    // Touching the oldest entry moves it back to the young end, so the next
    // write evicts the second-oldest instead.
    expect(cache.read('p0'), 1);
    cache.write('p200', 1);

    expect(cache.read('p0'), 1);
    expect(cache.read('p1'), isNull);
    expect(cache.read('p200'), 1);
  });
}
