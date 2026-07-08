import 'package:flutter_test/flutter_test.dart';
import 'package:krug/features/feed/feed_repository.dart';

void main() {
  group('Post.fromRow', () {
    test('parses a text-only post', () {
      final post = Post.fromRow({
        'id': 'post-1',
        'author_id': 'user-1',
        'author': {'name': 'Alice'},
        'text': 'Hello',
        'created_at': '2026-01-01T12:00:00Z',
      });

      expect(post.id, 'post-1');
      expect(post.authorName, 'Alice');
      expect(post.text, 'Hello');
      expect(post.imageUrl, null);
      expect(post.likeCount, 0);
      expect(post.likedByMe, false);
    });
  });

  group('Post.copyWith', () {
    test('overrides only the given fields', () {
      final post = Post.fromRow({
        'id': 'post-1',
        'author_id': 'user-1',
        'author': {'name': 'Alice'},
        'text': 'Hello',
        'created_at': '2026-01-01T12:00:00Z',
      });

      final liked = post.copyWith(likedByMe: true, likeCount: 1);

      expect(liked.likedByMe, true);
      expect(liked.likeCount, 1);
      expect(liked.text, 'Hello');
      expect(liked.id, 'post-1');
    });
  });

  group('Comment.fromRow', () {
    test('parses a comment row', () {
      final comment = Comment.fromRow({
        'id': 'comment-1',
        'author': {'name': 'Bob'},
        'text': 'Nice post!',
        'created_at': '2026-01-01T12:00:00Z',
      });

      expect(comment.id, 'comment-1');
      expect(comment.authorName, 'Bob');
      expect(comment.text, 'Nice post!');
    });
  });
}
