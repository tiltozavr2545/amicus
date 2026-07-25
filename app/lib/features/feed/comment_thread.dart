import 'feed_repository.dart';

/// One row of the comments screen: a root comment or one of its replies,
/// already in display order.
class ThreadedComment {
  const ThreadedComment({
    required this.comment,
    required this.isReply,
    this.replyToName,
  });

  final Comment comment;

  /// Whether to render this indented under its root.
  final bool isReply;

  /// Name for the `in reply to: <name>` label, set only when the reply addresses
  /// a *sibling* reply. A reply to the root itself needs no label — it already
  /// sits directly under the comment it answers.
  final String? replyToName;
}

/// Flattens [comments] (one post's comments, any order) into a display list:
/// each root followed by its own replies, both oldest first.
///
/// The chronological order is (re-)established here rather than trusted from the
/// query, so a reply can never be drawn above the comment it answers — that is
/// the whole point of a thread, and it is easy to lose to a sort default.
///
/// Two rows are dropped on the way, both for the same reason — a reply is only
/// meaningful next to what it replies to:
///
///  * a reply whose root is missing. Comments are visible only when their author
///    is the viewer or one of the viewer's connections, so a reply from a
///    connection can perfectly well outlive the visibility of the comment it
///    answers. Showing it as a root would tear it out of context, so the whole
///    branch stays hidden.
///  * a tombstoned root with no visible replies. A tombstone is kept server-side
///    only to hold a thread together; with nothing left under it, it is noise.
/// Oldest first, with the id as a tiebreak so comments sharing a timestamp
/// still land in a stable order.
int _byTime(Comment a, Comment b) {
  final byDate = a.createdAt.compareTo(b.createdAt);
  return byDate != 0 ? byDate : a.id.compareTo(b.id);
}

List<ThreadedComment> threadComments(List<Comment> comments) {
  final roots = <Comment>[];
  final repliesByRoot = <String, List<Comment>>{};
  final namesById = {for (final c in comments) c.id: c.authorName};

  for (final comment in comments) {
    final rootId = comment.parentCommentId;
    if (rootId == null) {
      roots.add(comment);
    } else {
      (repliesByRoot[rootId] ??= []).add(comment);
    }
  }

  roots.sort(_byTime);
  for (final replies in repliesByRoot.values) {
    replies.sort(_byTime);
  }

  final result = <ThreadedComment>[];
  for (final root in roots) {
    final replies = repliesByRoot[root.id] ?? const <Comment>[];
    if (root.isDeleted && replies.isEmpty) continue;

    result.add(ThreadedComment(comment: root, isReply: false));
    for (final reply in replies) {
      final addressee = reply.replyToId;
      result.add(
        ThreadedComment(
          comment: reply,
          isReply: true,
          replyToName: addressee == null || addressee == root.id
              ? null
              : namesById[addressee],
        ),
      );
    }
  }
  return result;
}
