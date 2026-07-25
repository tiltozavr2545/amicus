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

  // The feed adjusts the counters itself, before the server answers, so these
  // six transitions are what the user sees while the request is in flight.
  group('applyReaction', () {
    Post postWith({
      ReactionType? mine,
      int like = 10,
      int neutral = 5,
      int dislike = 2,
    }) => Post(
      id: 'p1',
      authorId: 'a1',
      authorName: 'Alice',
      createdAt: DateTime(2026, 1, 1),
      likeCount: like,
      neutralCount: neutral,
      dislikeCount: dislike,
      myReaction: mine,
      commentCount: 0,
    );

    test('adding a first reaction only raises that counter', () {
      final post = applyReaction(postWith(), ReactionType.like);

      expect(post.myReaction, ReactionType.like);
      expect(post.likeCount, 11);
      expect(post.neutralCount, 5);
      expect(post.dislikeCount, 2);
    });

    test('clearing your reaction only lowers that counter', () {
      final post = applyReaction(postWith(mine: ReactionType.dislike), null);

      expect(post.myReaction, null);
      expect(post.dislikeCount, 1);
      expect(post.likeCount, 10);
      expect(post.neutralCount, 5);
    });

    test('switching moves exactly one vote between two counters', () {
      final post = applyReaction(
        postWith(mine: ReactionType.like),
        ReactionType.dislike,
      );

      expect(post.myReaction, ReactionType.dislike);
      expect(post.likeCount, 9);
      expect(post.dislikeCount, 3);
      expect(post.neutralCount, 5);
      // The total across all three is what a switch must leave alone.
      expect(post.likeCount + post.neutralCount + post.dislikeCount, 17);
    });

    test(
      'every switch keeps the total, and every add/clear moves it by one',
      () {
        const types = [
          null,
          ReactionType.like,
          ReactionType.neutral,
          ReactionType.dislike,
        ];
        for (final from in types) {
          for (final to in types) {
            final before = postWith(mine: from);
            final after = applyReaction(before, to);
            final beforeTotal =
                before.likeCount + before.neutralCount + before.dislikeCount;
            final afterTotal =
                after.likeCount + after.neutralCount + after.dislikeCount;
            final expected =
                beforeTotal + (to == null ? 0 : 1) - (from == null ? 0 : 1);

            expect(
              afterTotal,
              expected,
              reason: 'total wrong going from $from to $to',
            );
            expect(after.myReaction, to, reason: 'myReaction wrong for $to');
          }
        }
      },
    );

    test('re-applying the reaction you already have is not a no-op', () {
      // The screen never calls it this way — it maps a repeat tap to null —
      // but the arithmetic still has to balance rather than double-count.
      final post = applyReaction(
        postWith(mine: ReactionType.like),
        ReactionType.like,
      );

      expect(post.likeCount, 10);
      expect(post.myReaction, ReactionType.like);
    });
  });

  group('keysetFilter', () {
    Post cursorAt(String createdAt, {String id = 'post-9'}) => Post.fromRow({
      'id': id,
      'author_id': 'user-1',
      'author': {'name': 'Alice'},
      'text': 'Hello',
      'created_at': createdAt,
    });

    test('returns null for the first page (no cursor)', () {
      expect(keysetFilter(null), isNull);
    });

    test('seeks strictly older than the cursor, with id as tiebreak', () {
      final filter = keysetFilter(cursorAt('2026-01-01T12:00:00Z'));
      expect(
        filter,
        'created_at.lt.2026-01-01T12:00:00.000Z,'
        'and(created_at.eq.2026-01-01T12:00:00.000Z,id.lt.post-9)',
      );
    });

    test('normalizes an offset timestamp to UTC so the filter has no "+"', () {
      // A "+03:00" offset would break the URL-encoded filter; toUtc() avoids it.
      final filter = keysetFilter(cursorAt('2026-01-01T15:00:00+03:00'));
      expect(filter, contains('created_at.lt.2026-01-01T12:00:00.000Z'));
      expect(filter, isNot(contains('+')));
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
