import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:amicus/features/feed/feed_cache.dart';
import 'package:amicus/features/feed/feed_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Post post({
    String id = 'post-1',
    String? text = 'Hello',
    String? imagePath,
    String? imageUrl,
    ReactionType? myReaction,
  }) => Post(
    id: id,
    authorId: 'author-1',
    authorName: 'Alice',
    createdAt: DateTime(2026, 1, 1, 12),
    authorDislikesDisabled: true,
    text: text,
    imagePath: imagePath,
    imageUrl: imageUrl,
    likeCount: 3,
    neutralCount: 1,
    dislikeCount: 0,
    myReaction: myReaction,
    commentCount: 2,
  );

  group('Post cache round trip', () {
    test('preserves every field, including a reaction', () {
      final original = post(
        imagePath: 'posts/author-1/token.jpg',
        imageUrl: 'https://example.invalid/signed',
        myReaction: ReactionType.like,
      );

      final restored = Post.fromCacheJson(original.toCacheJson());

      expect(restored.id, original.id);
      expect(restored.authorId, original.authorId);
      expect(restored.authorName, original.authorName);
      expect(restored.createdAt, original.createdAt);
      expect(restored.authorDislikesDisabled, original.authorDislikesDisabled);
      expect(restored.text, original.text);
      expect(restored.imagePath, original.imagePath);
      expect(restored.imageUrl, original.imageUrl);
      expect(restored.likeCount, original.likeCount);
      expect(restored.neutralCount, original.neutralCount);
      expect(restored.dislikeCount, original.dislikeCount);
      expect(restored.myReaction, original.myReaction);
      expect(restored.commentCount, original.commentCount);
    });

    test('round-trips a post with no photo and no reaction', () {
      final restored = Post.fromCacheJson(post().toCacheJson());

      expect(restored.imagePath, isNull);
      expect(restored.imageUrl, isNull);
      expect(restored.myReaction, isNull);
    });
  });

  group('FeedCache', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('load returns null when nothing was ever saved', () async {
      const cache = FeedCache();
      expect(await cache.load(null), isNull);
      expect(await cache.load('some-author'), isNull);
    });

    test('save then load round-trips the posts for that scope', () async {
      const cache = FeedCache();
      final posts = [post(id: 'p1'), post(id: 'p2', text: null)];

      await cache.save(null, posts);
      final loaded = await cache.load(null);

      expect(loaded, isNotNull);
      expect(loaded!.map((p) => p.id), ['p1', 'p2']);
    });

    test('the main feed and a specific author do not share a slot', () async {
      const cache = FeedCache();
      await cache.save(null, [post(id: 'main-post')]);
      await cache.save('author-9', [post(id: 'author-post')]);

      expect((await cache.load(null))!.single.id, 'main-post');
      expect((await cache.load('author-9'))!.single.id, 'author-post');
    });

    test('a later save for the same scope replaces the earlier one', () async {
      const cache = FeedCache();
      await cache.save(null, [post(id: 'stale')]);
      await cache.save(null, [post(id: 'fresh')]);

      expect((await cache.load(null))!.single.id, 'fresh');
    });

    test('corrupted cache contents are treated as no cache', () async {
      SharedPreferences.setMockInitialValues({'feed_cache_main': 'not json'});
      const cache = FeedCache();

      expect(await cache.load(null), isNull);
    });
  });
}
