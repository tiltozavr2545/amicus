import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:amicus/features/feed/feed_cache.dart';
import 'package:amicus/features/feed/feed_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Post post({
    String id = 'post-1',
    String? text = 'Hello',
    List<PostMedia> media = const [],
    ReactionType? myReaction,
  }) => Post(
    id: id,
    authorId: 'author-1',
    authorName: 'Alice',
    createdAt: DateTime(2026, 1, 1, 12),
    clientToken: 'client-token-1',
    authorDislikesDisabled: true,
    text: text,
    media: media,
    likeCount: 3,
    neutralCount: 1,
    dislikeCount: 0,
    myReaction: myReaction,
    commentCount: 2,
  );

  group('Post cache round trip', () {
    test('preserves every field, including a reaction and its media', () {
      final original = post(
        media: const [
          PostMedia(
            id: 'm1',
            position: 0,
            mediaType: MediaType.image,
            storagePath: 'posts/author-1/token/m1.jpg',
            url: 'https://example.invalid/signed',
          ),
          PostMedia(
            id: 'm2',
            position: 1,
            mediaType: MediaType.video,
            storagePath: 'posts/author-1/token/m2.mp4',
            posterPath: 'posts/author-1/token/m2_poster.jpg',
          ),
        ],
        myReaction: ReactionType.like,
      );

      final restored = Post.fromCacheJson(original.toCacheJson());

      expect(restored.id, original.id);
      expect(restored.authorId, original.authorId);
      expect(restored.authorName, original.authorName);
      expect(restored.createdAt, original.createdAt);
      expect(restored.clientToken, original.clientToken);
      expect(restored.authorDislikesDisabled, original.authorDislikesDisabled);
      expect(restored.text, original.text);
      expect(restored.media, hasLength(2));
      expect(restored.media[0].storagePath, original.media[0].storagePath);
      expect(restored.media[0].url, original.media[0].url);
      expect(restored.media[1].mediaType, MediaType.video);
      expect(restored.media[1].posterPath, original.media[1].posterPath);
      expect(restored.likeCount, original.likeCount);
      expect(restored.neutralCount, original.neutralCount);
      expect(restored.dislikeCount, original.dislikeCount);
      expect(restored.myReaction, original.myReaction);
      expect(restored.commentCount, original.commentCount);
    });

    test('round-trips a post with no media and no reaction', () {
      final restored = Post.fromCacheJson(post().toCacheJson());

      expect(restored.media, isEmpty);
      expect(restored.myReaction, isNull);
    });

    test(
      'a cache entry from before multi-media (no media key) degrades to no photo',
      () {
        final legacyJson = post().toCacheJson()..remove('media');

        final restored = Post.fromCacheJson(legacyJson);

        expect(restored.media, isEmpty);
      },
    );
  });

  group('FeedCache', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('load returns null when nothing was ever saved', () async {
      const cache = FeedCache();
      expect(await cache.load('viewer-1', null), isNull);
      expect(await cache.load('viewer-1', 'some-author'), isNull);
    });

    test('save then load round-trips the posts for that scope', () async {
      const cache = FeedCache();
      final posts = [post(id: 'p1'), post(id: 'p2', text: null)];

      await cache.save('viewer-1', null, posts);
      final loaded = await cache.load('viewer-1', null);

      expect(loaded, isNotNull);
      expect(loaded!.map((p) => p.id), ['p1', 'p2']);
    });

    test('the main feed and a specific author do not share a slot', () async {
      const cache = FeedCache();
      await cache.save('viewer-1', null, [post(id: 'main-post')]);
      await cache.save('viewer-1', 'author-9', [post(id: 'author-post')]);

      expect((await cache.load('viewer-1', null))!.single.id, 'main-post');
      expect(
        (await cache.load('viewer-1', 'author-9'))!.single.id,
        'author-post',
      );
    });

    test('a later save for the same scope replaces the earlier one', () async {
      const cache = FeedCache();
      await cache.save('viewer-1', null, [post(id: 'stale')]);
      await cache.save('viewer-1', null, [post(id: 'fresh')]);

      expect((await cache.load('viewer-1', null))!.single.id, 'fresh');
    });

    // The whole point of scoping by viewer: signing in as someone else on
    // this device must not surface the previous account's feed, which holds
    // posts RLS only ever showed to them.
    test('another viewer does not see this one cached page', () async {
      const cache = FeedCache();
      await cache.save('viewer-1', null, [post(id: 'private-to-viewer-1')]);

      expect(await cache.load('viewer-2', null), isNull);
      expect(await cache.load(null, null), isNull);
    });

    test('the same scope for two viewers keeps two slots', () async {
      const cache = FeedCache();
      await cache.save('viewer-1', null, [post(id: 'one')]);
      await cache.save('viewer-2', null, [post(id: 'two')]);

      expect((await cache.load('viewer-1', null))!.single.id, 'one');
      expect((await cache.load('viewer-2', null))!.single.id, 'two');
    });

    test('clear drops every viewer and every scope', () async {
      const cache = FeedCache();
      await cache.save('viewer-1', null, [post(id: 'a')]);
      await cache.save('viewer-1', 'author-9', [post(id: 'b')]);
      await cache.save('viewer-2', null, [post(id: 'c')]);

      await cache.clear();

      expect(await cache.load('viewer-1', null), isNull);
      expect(await cache.load('viewer-1', 'author-9'), isNull);
      expect(await cache.load('viewer-2', null), isNull);
    });

    // Entries written before the keys were scoped by viewer are exactly the
    // ones a sign-out most needs to remove, so clear() matches on the prefix
    // rather than reconstructing one viewer's keys.
    test('clear also drops unscoped keys from an older build', () async {
      SharedPreferences.setMockInitialValues({
        'feed_cache_main': '[]',
        'unrelated_key': 'kept',
      });
      const cache = FeedCache();

      await cache.clear();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('feed_cache_main'), isNull);
      expect(prefs.getString('unrelated_key'), 'kept');
    });

    test('clear on an empty store is a no-op', () async {
      const cache = FeedCache();
      await cache.clear();
      expect(await cache.load('viewer-1', null), isNull);
    });

    test('corrupted cache contents are treated as no cache', () async {
      SharedPreferences.setMockInitialValues({
        'feed_cache_viewer-1_main': 'not json',
      });
      const cache = FeedCache();

      expect(await cache.load('viewer-1', null), isNull);
    });
  });
}
