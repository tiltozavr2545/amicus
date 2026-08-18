import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/network_timeout.dart';
import '../../shared/parse_timestamp.dart';
import '../auth/auth_providers.dart';

/// The three mutually-exclusive reactions a user can leave on a post. Stored
/// in `reactions.type` as the enum's [name] (`like` / `neutral` / `dislike`).
enum ReactionType {
  like,
  neutral,
  dislike;

  static ReactionType fromDb(String value) => ReactionType.values.byName(value);

  String get dbValue => name;
}

/// Sentinel so [Post.copyWith] can tell "leave myReaction unchanged" apart
/// from "clear it to null" — a plain nullable parameter can't express both.
const Object _unchanged = Object();

class Post {
  const Post({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.createdAt,
    this.authorDislikesDisabled = false,
    this.text,
    this.imagePath,
    this.imageUrl,
    this.likeCount = 0,
    this.neutralCount = 0,
    this.dislikeCount = 0,
    this.myReaction,
    this.commentCount = 0,
  });

  final String id;
  final String authorId;
  final String authorName;
  final DateTime createdAt;

  /// The author opted out of negative reactions: the dislike button is hidden
  /// under their posts (and the database rejects a dislike on them). Sourced
  /// from the author's profile, so nothing in this code names a specific user.
  final bool authorDislikesDisabled;
  final String? text;
  final String? imagePath;
  final String? imageUrl;
  final int likeCount;
  final int neutralCount;
  final int dislikeCount;

  /// The current user's reaction on this post, or null if they haven't reacted.
  final ReactionType? myReaction;
  final int commentCount;

  factory Post.fromRow(Map<String, dynamic> row) {
    return Post(
      id: row['id'] as String,
      authorId: row['author_id'] as String,
      authorName: (row['author'] as Map<String, dynamic>)['name'] as String,
      createdAt: parseTimestamp(row['created_at'] as String),
      authorDislikesDisabled:
          (row['author'] as Map<String, dynamic>)['dislikes_disabled']
              as bool? ??
          false,
      text: row['text'] as String?,
      imagePath: row['image_path'] as String?,
    );
  }

  Post copyWith({
    String? imageUrl,
    int? likeCount,
    int? neutralCount,
    int? dislikeCount,
    Object? myReaction = _unchanged,
    int? commentCount,
  }) {
    return Post(
      id: id,
      authorId: authorId,
      authorName: authorName,
      createdAt: createdAt,
      authorDislikesDisabled: authorDislikesDisabled,
      text: text,
      imagePath: imagePath,
      imageUrl: imageUrl ?? this.imageUrl,
      likeCount: likeCount ?? this.likeCount,
      neutralCount: neutralCount ?? this.neutralCount,
      dislikeCount: dislikeCount ?? this.dislikeCount,
      myReaction: identical(myReaction, _unchanged)
          ? this.myReaction
          : myReaction as ReactionType?,
      commentCount: commentCount ?? this.commentCount,
    );
  }
}

/// Returns [post] with its counters and `myReaction` moved from whatever the
/// viewer had to [next] (null = no reaction at all).
///
/// The feed applies this optimistically, before the server has confirmed
/// anything, so it has to do the same arithmetic the server would: take one off
/// the old counter, add one to the new. Lives here as a pure function rather
/// than inside the screen's State so the six transitions can be tested — the
/// counters are what the user actually looks at, and an off-by-one here is
/// invisible until someone counts.
Post applyReaction(Post post, ReactionType? next) {
  var like = post.likeCount;
  var neutral = post.neutralCount;
  var dislike = post.dislikeCount;
  switch (post.myReaction) {
    case ReactionType.like:
      like--;
    case ReactionType.neutral:
      neutral--;
    case ReactionType.dislike:
      dislike--;
    case null:
      break;
  }
  switch (next) {
    case ReactionType.like:
      like++;
    case ReactionType.neutral:
      neutral++;
    case ReactionType.dislike:
      dislike++;
    case null:
      break;
  }
  return post.copyWith(
    likeCount: like,
    neutralCount: neutral,
    dislikeCount: dislike,
    myReaction: next,
  );
}

class Comment {
  const Comment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.text,
    required this.createdAt,
    this.parentCommentId,
    this.replyToId,
    this.isDeleted = false,
  });

  final String id;
  final String authorId;
  final String authorName;
  final String text;
  final DateTime createdAt;

  /// The thread root this comment belongs to; null for a root comment. Replies
  /// are capped at one level, so a reply's parent is always a root.
  final String? parentCommentId;

  /// The comment this reply is addressed to — the root itself or a sibling
  /// reply. Display only: it never affects nesting.
  final String? replyToId;

  /// A comment that was deleted while it still had replies: the row survives so
  /// the thread stays readable, but [text] has been erased server-side.
  final bool isDeleted;

  factory Comment.fromRow(Map<String, dynamic> row) {
    return Comment(
      id: row['id'] as String,
      authorId: row['author_id'] as String,
      authorName: (row['author'] as Map<String, dynamic>)['name'] as String,
      text: row['text'] as String,
      createdAt: parseTimestamp(row['created_at'] as String),
      parentCommentId: row['parent_comment_id'] as String?,
      replyToId: row['reply_to_id'] as String?,
      isDeleted: row['deleted_at'] != null,
    );
  }
}

const _bucket = 'media';
const pageSize = 20;

/// Builds the PostgREST keyset filter for the page strictly *older* than
/// [cursor], newest-first. Returns null for the first page (no cursor).
///
/// Keyset (seek) paging instead of offset paging: the window is anchored to the
/// last post already seen — `created_at < cursor` — rather than to a numeric
/// offset. That way posts inserted at (or deleted from) the top between page
/// loads can't shift the offset and cause a post to be shown twice or skipped.
/// `created_at` alone isn't unique, so `id` is a deterministic tiebreak for the
/// rare case of two posts sharing the exact same timestamp at a page boundary.
String? keysetFilter(Post? cursor) {
  if (cursor == null) return null;
  final ts = cursor.createdAt.toUtc().toIso8601String();
  return 'created_at.lt.$ts,and(created_at.eq.$ts,id.lt.${cursor.id})';
}

/// Storage path for a post's photo.
///
/// Two things are load-bearing here. The first two segments are what the
/// storage policies match on — `posts/<author uuid>/…` — so reshaping this
/// silently breaks upload (the INSERT policy pins segment 2 to `auth.uid()`)
/// or visibility (the SELECT policy reads the author out of that segment).
///
/// The filename is the submission's [clientToken] rather than a timestamp, so
/// every retry of the same submission addresses the same object. Naming it per
/// attempt meant a retry uploaded a *second* file while the row — resolved by
/// `ON CONFLICT DO NOTHING` — kept pointing at the first, and since deletePost
/// only removes the path stored on the row, each extra upload leaked into the
/// bucket permanently.
String postImagePath({
  required String authorId,
  required String clientToken,
  required String imageExt,
}) => 'posts/$authorId/$clientToken.$imageExt';

class FeedRepository {
  FeedRepository(this._client);

  final SupabaseClient _client;

  /// Fetches one page of the feed (newest first), starting strictly after
  /// [cursor] (the last post of the previous page; null for the first page).
  /// When [authorId] is set, only that author's posts are returned — used by
  /// the profile screen's "my posts" list, layered on top of the same RLS
  /// visibility rather than replacing it.
  /// A signed URL is resolved for each post's photo (the `media` bucket is
  /// private, so a plain public URL wouldn't be servable), plus
  /// reaction/comment counts.
  Future<List<Post>> fetchPage({Post? cursor, String? authorId}) async {
    var query = _client
        .from('posts')
        .select('*, author:users(name, dislikes_disabled)');
    if (authorId != null) {
      query = query.eq('author_id', authorId);
    }
    final filter = keysetFilter(cursor);
    if (filter != null) {
      query = query.or(filter);
    }
    final rows = await query
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(pageSize)
        .timeout(networkTimeout);

    var posts = rows.map(Post.fromRow).toList();
    if (posts.isEmpty) return posts;

    final postIds = posts.map((p) => p.id).toList();

    // Reaction *counts* are public to anyone who can see the post, but who
    // reacted is not: the reactions table only exposes the caller's own rows,
    // so totals come from a server-side function that returns numbers plus the
    // caller's own reaction — never other users' ids.
    //
    // Counts every comment including replies, but not tombstones (a deleted
    // comment's row survives only to keep its branch readable and holds no
    // text). Server-side: the comments SELECT policy already gates exactly
    // these rows, so `comment_summary` needs no visibility logic of its own.
    //
    // Neither RPC depends on the other's result, so they run concurrently
    // instead of costing the page an extra round trip.
    final results = await Future.wait([
      _client
          .rpc('reaction_summary', params: {'p_post_ids': postIds})
          .timeout(networkTimeout),
      _client
          .rpc('comment_summary', params: {'p_post_ids': postIds})
          .timeout(networkTimeout),
    ]);
    final summaryRows = results[0] as List<dynamic>;
    final commentSummaryRows = results[1] as List<dynamic>;

    final likeCounts = <String, int>{};
    final neutralCounts = <String, int>{};
    final dislikeCounts = <String, int>{};
    final myReactions = <String, ReactionType>{};
    for (final row in summaryRows.cast<Map<String, dynamic>>()) {
      final postId = row['post_id'] as String;
      likeCounts[postId] = (row['like_count'] as num).toInt();
      neutralCounts[postId] = (row['neutral_count'] as num).toInt();
      dislikeCounts[postId] = (row['dislike_count'] as num).toInt();
      final mine = row['my_reaction'] as String?;
      if (mine != null) myReactions[postId] = ReactionType.fromDb(mine);
    }

    final commentCounts = <String, int>{};
    for (final row in commentSummaryRows.cast<Map<String, dynamic>>()) {
      final postId = row['post_id'] as String;
      commentCounts[postId] = (row['comment_count'] as num).toInt();
    }

    posts = posts
        .map(
          (post) => post.copyWith(
            likeCount: likeCounts[post.id] ?? 0,
            neutralCount: neutralCounts[post.id] ?? 0,
            dislikeCount: dislikeCounts[post.id] ?? 0,
            myReaction: myReactions[post.id],
            commentCount: commentCounts[post.id] ?? 0,
          ),
        )
        .toList();

    return Future.wait(
      List.generate(posts.length, (i) async {
        final path = rows[i]['image_path'] as String?;
        if (path == null) return posts[i];
        final url = await _client.storage
            .from(_bucket)
            .createSignedUrl(path, 60 * 60 * 24)
            .timeout(networkTimeout);
        return posts[i].copyWith(imageUrl: url);
      }),
    );
  }

  /// [clientToken] identifies this *submission* — the caller mints one uuid per
  /// composed post and reuses it for every retry of that same content.
  ///
  /// `.timeout()` doesn't cancel the underlying request, it only stops waiting,
  /// so a slow-but-live connection can commit the insert after the screen has
  /// already reported failure and offered a retry. The unique
  /// `(author_id, client_token)` index turns that retry into a no-op instead of
  /// a second post. The conflict target is deliberately not `id`: scoping it to
  /// the author means a collision can only ever be with the caller's own row,
  /// so this can't be used to probe whether someone else's post exists.
  Future<void> createPost({
    required String clientToken,
    required String authorId,
    String? text,
    Uint8List? imageBytes,
    String? imageExt,
  }) async {
    String? imagePath;
    if (imageBytes != null) {
      imagePath = postImagePath(
        authorId: authorId,
        clientToken: clientToken,
        imageExt: imageExt ?? 'jpg',
      );
      try {
        await _client.storage
            .from(_bucket)
            .uploadBinary(imagePath, imageBytes)
            .timeout(networkTimeout);
      } on StorageException catch (e) {
        // 409: a previous attempt at this same submission already put these
        // exact bytes at this exact path. There is no UPDATE policy on
        // storage.objects for post photos (only SELECT/INSERT/DELETE), so
        // overwriting via `upsert: true` would be refused by RLS — and there is
        // nothing to overwrite anyway, the content is identical.
        if (e.statusCode != '409') rethrow;
      }
    }
    await _client
        .from('posts')
        .upsert(
          {
            'client_token': clientToken,
            'author_id': authorId,
            if (text != null && text.isNotEmpty) 'text': text,
            if (imagePath != null) 'image_path': imagePath,
          },
          onConflict: 'author_id,client_token',
          ignoreDuplicates: true,
        )
        .timeout(networkTimeout);
  }

  /// Sets (or switches) the current user's reaction on a post. Upserts onto
  /// the unique (post_id, user_id) row, so switching like -> dislike replaces
  /// the type rather than adding a second reaction.
  Future<void> setReaction({
    required String postId,
    required String userId,
    required ReactionType type,
  }) async {
    await _client
        .from('reactions')
        .upsert({
          'post_id': postId,
          'user_id': userId,
          'type': type.dbValue,
        }, onConflict: 'post_id, user_id')
        .timeout(networkTimeout);
  }

  Future<void> removeReaction({
    required String postId,
    required String userId,
  }) async {
    await _client
        .from('reactions')
        .delete()
        .eq('post_id', postId)
        .eq('user_id', userId)
        .timeout(networkTimeout);
  }

  /// Fetches one post's comments, oldest first — a conversation reads forwards,
  /// and replies have to follow the comment they answer.
  ///
  /// `ascending: true` is spelled out because postgrest-dart's `order()`
  /// defaults to *descending*; `id` is a deterministic tiebreak for comments
  /// sharing a timestamp, same as the feed's keyset paging.
  Future<List<Comment>> fetchComments(String postId) async {
    final rows = await _client
        .from('comments')
        .select('*, author:users(name)')
        .eq('post_id', postId)
        .order('created_at', ascending: true)
        .order('id', ascending: true)
        .timeout(networkTimeout);
    return rows.map(Comment.fromRow).toList();
  }

  /// Adds a comment, or a reply when [parentCommentId] is given (always the
  /// thread root — nesting is one level deep). [replyToId] only records who the
  /// reply addresses, for the `in reply to: <name>` label.
  ///
  /// [clientToken] identifies this submission and is reused across retries of
  /// the same content — see the matching note on [createPost].
  Future<void> addComment({
    required String clientToken,
    required String postId,
    required String authorId,
    required String text,
    String? parentCommentId,
    String? replyToId,
  }) async {
    await _client
        .from('comments')
        .upsert(
          {
            'client_token': clientToken,
            'post_id': postId,
            'author_id': authorId,
            'text': text,
            'parent_comment_id': parentCommentId,
            'reply_to_id': replyToId,
          },
          onConflict: 'author_id,client_token',
          ignoreDuplicates: true,
        )
        .timeout(networkTimeout);
  }

  /// Deletes a post the current user owns. Comments/reactions cascade via
  /// their FK to `posts`, but the photo lives in Storage, not Postgres, so
  /// it's removed separately.
  Future<void> deletePost({required String postId, String? imagePath}) async {
    if (imagePath != null) {
      await _client.storage
          .from(_bucket)
          .remove([imagePath])
          .timeout(networkTimeout);
    }
    await _client
        .from('posts')
        .delete()
        .eq('id', postId)
        .timeout(networkTimeout);
  }

  /// Deletes a comment of the current user's. Whether the row is removed or
  /// merely tombstoned is decided server-side (a comment with replies is
  /// tombstoned so those replies keep their context), hence the RPC instead of
  /// a plain delete.
  Future<void> deleteComment(String commentId) async {
    await _client
        .rpc('delete_own_comment', params: {'p_comment_id': commentId})
        .timeout(networkTimeout);
  }
}

final feedRepositoryProvider = Provider<FeedRepository>((ref) {
  return FeedRepository(ref.watch(supabaseClientProvider));
});

/// Bumped whenever something outside [FeedScreen] changes what the feed should
/// show, so it can refresh itself: a post created from the bottom-nav "new
/// post" tab, and muting/blocking (or unmuting/unblocking) a connection, which
/// changes which authors RLS lets through. The feed tab keeps its state in the
/// shell's IndexedStack, so without this it would sit on a stale page.
class FeedRefreshTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final feedRefreshTickProvider = NotifierProvider<FeedRefreshTick, int>(
  FeedRefreshTick.new,
);
