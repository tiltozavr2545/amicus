import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/features/feed/comment_thread.dart';
import 'package:amicus/features/feed/feed_repository.dart';

Comment commentAt(
  String id, {
  required String minute,
  String author = 'Alice',
  String? parentCommentId,
  String? replyToId,
  bool deleted = false,
}) {
  return Comment.fromRow({
    'id': id,
    'author_id': 'user-$author',
    'author': {'name': author},
    'text': 'text of $id',
    'created_at': '2026-01-01T12:$minute:00Z',
    'parent_comment_id': parentCommentId,
    'reply_to_id': replyToId,
    'deleted_at': deleted ? '2026-01-02T12:00:00Z' : null,
  });
}

void main() {
  group('Comment.fromRow', () {
    test('reads the threading columns and the tombstone marker', () {
      final reply = commentAt(
        'c2',
        minute: '01',
        parentCommentId: 'c1',
        replyToId: 'c1',
      );

      expect(reply.parentCommentId, 'c1');
      expect(reply.replyToId, 'c1');
      expect(reply.isDeleted, false);
      expect(commentAt('c3', minute: '02', deleted: true).isDeleted, true);
    });
  });

  group('threadComments', () {
    test('puts each root ahead of its own replies', () {
      final threaded = threadComments([
        commentAt('root-a', minute: '00'),
        commentAt('root-b', minute: '01'),
        commentAt('reply-a', minute: '02', parentCommentId: 'root-a'),
        commentAt('reply-b', minute: '03', parentCommentId: 'root-b'),
        commentAt('reply-a2', minute: '04', parentCommentId: 'root-a'),
      ]);

      expect(threaded.map((t) => t.comment.id), [
        'root-a',
        'reply-a',
        'reply-a2',
        'root-b',
        'reply-b',
      ]);
      expect(threaded.map((t) => t.isReply), [false, true, true, false, true]);
    });

    test(
      'orders roots and replies oldest first whatever order they arrive in',
      () {
        // Regression: postgrest-dart's order() defaults to descending, so the
        // query used to hand these back newest first and a reply was drawn above
        // the comment it answered.
        final threaded = threadComments([
          commentAt('reply-late', minute: '03', parentCommentId: 'root-old'),
          commentAt('root-new', minute: '02'),
          commentAt('reply-early', minute: '01', parentCommentId: 'root-old'),
          commentAt('root-old', minute: '00'),
        ]);

        expect(threaded.map((t) => t.comment.id), [
          'root-old',
          'reply-early',
          'reply-late',
          'root-new',
        ]);
      },
    );

    test('breaks a timestamp tie by id so the order stays stable', () {
      final threaded = threadComments([
        commentAt('root-b', minute: '00'),
        commentAt('root-a', minute: '00'),
      ]);

      expect(threaded.map((t) => t.comment.id), ['root-a', 'root-b']);
    });

    test('labels a reply addressed to a sibling, but not one to the root', () {
      final threaded = threadComments([
        commentAt('root', minute: '00', author: 'Alice'),
        commentAt(
          'reply-1',
          minute: '01',
          author: 'Bob',
          parentCommentId: 'root',
          replyToId: 'root',
        ),
        commentAt(
          'reply-2',
          minute: '02',
          author: 'Carol',
          parentCommentId: 'root',
          replyToId: 'reply-1',
        ),
      ]);

      expect(threaded[1].replyToName, isNull);
      expect(threaded[2].replyToName, 'Bob');
    });

    test('hides a branch whose root is not visible to the viewer', () {
      // The root's author is not one of the viewer's connections, so RLS never
      // returned it; the reply alone would be out of context.
      final threaded = threadComments([
        commentAt('root-visible', minute: '00'),
        commentAt('orphan', minute: '01', parentCommentId: 'root-hidden'),
      ]);

      expect(threaded.map((t) => t.comment.id), ['root-visible']);
    });

    test('keeps a tombstoned root that still holds replies', () {
      final threaded = threadComments([
        commentAt('root', minute: '00', deleted: true),
        commentAt('reply', minute: '01', parentCommentId: 'root'),
      ]);

      expect(threaded.map((t) => t.comment.id), ['root', 'reply']);
      expect(threaded.first.comment.isDeleted, true);
    });

    test('drops a tombstoned root once nothing is left under it', () {
      final threaded = threadComments([
        commentAt('root', minute: '00', deleted: true),
        commentAt('other', minute: '01'),
      ]);

      expect(threaded.map((t) => t.comment.id), ['other']);
    });

    test('returns an empty list for a post with no comments', () {
      expect(threadComments([]), isEmpty);
    });
  });
}
