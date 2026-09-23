import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/shared/signed_url_cache.dart';
import 'package:amicus/shared/signed_urls.dart';

void main() {
  test('a written URL is handed straight back', () {
    final cache = SignedUrlCache()
      ..write({'messages/a.jpg': 'https://example.invalid/a'});

    expect(cache.read(['messages/a.jpg']), {
      'messages/a.jpg': 'https://example.invalid/a',
    });
  });

  test('a path never written is simply absent, not null', () {
    final cache = SignedUrlCache()
      ..write({'messages/a.jpg': 'https://example.invalid/a'});

    // Same shape `resolveSignedUrls` answers in, so the two are
    // interchangeable at the call site.
    expect(cache.read(['messages/a.jpg', 'messages/b.jpg']), {
      'messages/a.jpg': 'https://example.invalid/a',
    });
  });

  test('a signature is dropped before it actually lapses', () {
    var now = DateTime.utc(2026, 9, 23, 12);
    final cache = SignedUrlCache(now: () => now)
      ..write({'messages/a.jpg': 'https://example.invalid/a'});

    // Still good for a couple of minutes by the clock, but not long enough to
    // survive being handed out, so it is already a miss.
    now = now
        .add(const Duration(seconds: signedUrlTtl))
        .subtract(const Duration(minutes: 2));

    expect(cache.read(['messages/a.jpg']), isEmpty);
  });

  test('a signature well inside its TTL is still a hit', () {
    var now = DateTime.utc(2026, 9, 23, 12);
    final cache = SignedUrlCache(now: () => now)
      ..write({'messages/a.jpg': 'https://example.invalid/a'});

    now = now.add(const Duration(hours: 12));

    expect(cache.read(['messages/a.jpg']), isNotEmpty);
  });

  test('re-signing a path replaces its URL', () {
    final cache = SignedUrlCache()
      ..write({'messages/a.jpg': 'https://example.invalid/old'})
      ..write({'messages/a.jpg': 'https://example.invalid/new'});

    expect(cache.read(['messages/a.jpg']), {
      'messages/a.jpg': 'https://example.invalid/new',
    });
  });

  test('the oldest signatures are dropped once it is full', () {
    final cache = SignedUrlCache();
    // One past capacity: the first path written is the one that goes.
    for (var i = 0; i <= 512; i++) {
      cache.write({'messages/$i.jpg': 'https://example.invalid/$i'});
    }

    expect(cache.read(['messages/0.jpg']), isEmpty);
    expect(cache.read(['messages/1.jpg']), isNotEmpty);
    expect(cache.read(['messages/512.jpg']), isNotEmpty);
  });

  test('sign-out leaves nothing behind for the next account', () {
    final cache = SignedUrlCache()
      ..write({'messages/a.jpg': 'https://example.invalid/a'})
      ..clear();

    expect(cache.read(['messages/a.jpg']), isEmpty);
  });
}
