import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/features/feed/feed_repository.dart';

void main() {
  group('Post.fromRow', () {
    test('parses a text-only post with no reactions yet', () {
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
      expect(post.neutralCount, 0);
      expect(post.dislikeCount, 0);
      expect(post.myReaction, null);
      expect(post.authorDislikesDisabled, false);
    });

    test('reads the author opt-out flag when present', () {
      final post = Post.fromRow({
        'id': 'post-1',
        'author_id': 'user-1',
        'author': {'name': 'Alice', 'dislikes_disabled': true},
        'text': 'Hello',
        'created_at': '2026-01-01T12:00:00Z',
      });

      expect(post.authorDislikesDisabled, true);
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

      final liked = post.copyWith(myReaction: ReactionType.like, likeCount: 1);

      expect(liked.myReaction, ReactionType.like);
      expect(liked.likeCount, 1);
      expect(liked.text, 'Hello');
      expect(liked.id, 'post-1');
    });

    test('preserves the author opt-out flag across copies', () {
      final post = Post.fromRow({
        'id': 'post-1',
        'author_id': 'user-1',
        'author': {'name': 'Alice', 'dislikes_disabled': true},
        'text': 'Hello',
        'created_at': '2026-01-01T12:00:00Z',
      });

      expect(post.copyWith(likeCount: 5).authorDislikesDisabled, true);
    });

    test('can clear myReaction back to null', () {
      final liked = Post.fromRow({
        'id': 'post-1',
        'author_id': 'user-1',
        'author': {'name': 'Alice'},
        'created_at': '2026-01-01T12:00:00Z',
      }).copyWith(myReaction: ReactionType.dislike, dislikeCount: 1);

      final cleared = liked.copyWith(myReaction: null, dislikeCount: 0);

      expect(cleared.myReaction, null);
      expect(cleared.dislikeCount, 0);
    });
  });

  group('ReactionType', () {
    test('round-trips through its database value', () {
      for (final type in ReactionType.values) {
        expect(ReactionType.fromDb(type.dbValue), type);
      }
    });
  });

  group('Comment.fromRow', () {
    test('parses a comment row', () {
      final comment = Comment.fromRow({
        'id': 'comment-1',
        'author_id': 'user-2',
        'author': {'name': 'Bob'},
        'text': 'Nice post!',
        'created_at': '2026-01-01T12:00:00Z',
      });

      expect(comment.id, 'comment-1');
      expect(comment.authorId, 'user-2');
      expect(comment.authorName, 'Bob');
      expect(comment.text, 'Nice post!');
    });
  });
}
