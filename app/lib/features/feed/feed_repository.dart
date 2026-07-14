import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
      createdAt: DateTime.parse(row['created_at'] as String),
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

class Comment {
  const Comment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String authorId;
  final String authorName;
  final String text;
  final DateTime createdAt;

  factory Comment.fromRow(Map<String, dynamic> row) {
    return Comment(
      id: row['id'] as String,
      authorId: row['author_id'] as String,
      authorName: (row['author'] as Map<String, dynamic>)['name'] as String,
      text: row['text'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
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

class FeedRepository {
  FeedRepository(this._client);

  final SupabaseClient _client;

  /// Fetches one page of the feed (newest first), starting strictly after
  /// [cursor] (the last post of the previous page; null for the first page).
  /// A signed URL is resolved for each post's photo (the `media` bucket is
  /// private, so a plain public URL wouldn't be servable), plus
  /// reaction/comment counts.
  Future<List<Post>> fetchPage({Post? cursor}) async {
    var query = _client
        .from('posts')
        .select('*, author:users(name, dislikes_disabled)');
    final filter = keysetFilter(cursor);
    if (filter != null) {
      query = query.or(filter);
    }
    final rows = await query
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(pageSize);

    var posts = rows.map(Post.fromRow).toList();
    if (posts.isEmpty) return posts;

    final postIds = posts.map((p) => p.id).toList();

    // Reaction *counts* are public to anyone who can see the post, but who
    // reacted is not: the reactions table only exposes the caller's own rows,
    // so totals come from a server-side function that returns numbers plus the
    // caller's own reaction — never other users' ids.
    final summaryRows =
        await _client.rpc('reaction_summary', params: {'p_post_ids': postIds})
            as List<dynamic>;
    final commentRows = await _client
        .from('comments')
        .select('post_id')
        .inFilter('post_id', postIds);

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
    for (final row in commentRows) {
      final postId = row['post_id'] as String;
      commentCounts[postId] = (commentCounts[postId] ?? 0) + 1;
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
            .createSignedUrl(path, 60 * 60 * 24);
        return posts[i].copyWith(imageUrl: url);
      }),
    );
  }

  Future<void> createPost({
    required String authorId,
    String? text,
    Uint8List? imageBytes,
    String? imageExt,
  }) async {
    String? imagePath;
    if (imageBytes != null) {
      imagePath =
          'posts/$authorId/${DateTime.now().microsecondsSinceEpoch}.$imageExt';
      await _client.storage.from(_bucket).uploadBinary(imagePath, imageBytes);
    }
    await _client.from('posts').insert({
      'author_id': authorId,
      if (text != null && text.isNotEmpty) 'text': text,
      if (imagePath != null) 'image_path': imagePath,
    });
  }

  /// Sets (or switches) the current user's reaction on a post. Upserts onto
  /// the unique (post_id, user_id) row, so switching like -> dislike replaces
  /// the type rather than adding a second reaction.
  Future<void> setReaction({
    required String postId,
    required String userId,
    required ReactionType type,
  }) async {
    await _client.from('reactions').upsert({
      'post_id': postId,
      'user_id': userId,
      'type': type.dbValue,
    }, onConflict: 'post_id, user_id');
  }

  Future<void> removeReaction({
    required String postId,
    required String userId,
  }) async {
    await _client
        .from('reactions')
        .delete()
        .eq('post_id', postId)
        .eq('user_id', userId);
  }

  Future<List<Comment>> fetchComments(String postId) async {
    final rows = await _client
        .from('comments')
        .select('*, author:users(name)')
        .eq('post_id', postId)
        .order('created_at');
    return rows.map(Comment.fromRow).toList();
  }

  Future<void> addComment({
    required String postId,
    required String authorId,
    required String text,
  }) async {
    await _client.from('comments').insert({
      'post_id': postId,
      'author_id': authorId,
      'text': text,
    });
  }

  /// Deletes a post the current user owns. Comments/reactions cascade via
  /// their FK to `posts`, but the photo lives in Storage, not Postgres, so
  /// it's removed separately.
  Future<void> deletePost({required String postId, String? imagePath}) async {
    if (imagePath != null) {
      await _client.storage.from(_bucket).remove([imagePath]);
    }
    await _client.from('posts').delete().eq('id', postId);
  }

  Future<void> deleteComment(String commentId) async {
    await _client.from('comments').delete().eq('id', commentId);
  }
}

final feedRepositoryProvider = Provider<FeedRepository>((ref) {
  return FeedRepository(ref.watch(supabaseClientProvider));
});

/// Bumped by the bottom-nav shell after a post is created from outside
/// [FeedScreen] (the "new post" tab), so the feed knows to refresh itself.
class FeedRefreshTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final feedRefreshTickProvider = NotifierProvider<FeedRefreshTick, int>(
  FeedRefreshTick.new,
);
