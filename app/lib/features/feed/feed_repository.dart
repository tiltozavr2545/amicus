import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';

class Post {
  const Post({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.createdAt,
    this.text,
    this.imageUrl,
    this.likeCount = 0,
    this.likedByMe = false,
    this.commentCount = 0,
  });

  final String id;
  final String authorId;
  final String authorName;
  final DateTime createdAt;
  final String? text;
  final String? imageUrl;
  final int likeCount;
  final bool likedByMe;
  final int commentCount;

  factory Post.fromRow(Map<String, dynamic> row) {
    return Post(
      id: row['id'] as String,
      authorId: row['author_id'] as String,
      authorName: (row['author'] as Map<String, dynamic>)['name'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      text: row['text'] as String?,
    );
  }

  Post copyWith({
    String? imageUrl,
    int? likeCount,
    bool? likedByMe,
    int? commentCount,
  }) {
    return Post(
      id: id,
      authorId: authorId,
      authorName: authorName,
      createdAt: createdAt,
      text: text,
      imageUrl: imageUrl ?? this.imageUrl,
      likeCount: likeCount ?? this.likeCount,
      likedByMe: likedByMe ?? this.likedByMe,
      commentCount: commentCount ?? this.commentCount,
    );
  }
}

class Comment {
  const Comment({
    required this.id,
    required this.authorName,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String authorName;
  final String text;
  final DateTime createdAt;

  factory Comment.fromRow(Map<String, dynamic> row) {
    return Comment(
      id: row['id'] as String,
      authorName: (row['author'] as Map<String, dynamic>)['name'] as String,
      text: row['text'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}

const _bucket = 'media';
const pageSize = 20;

class FeedRepository {
  FeedRepository(this._client);

  final SupabaseClient _client;

  /// Fetches one page of the feed (newest first), with a signed URL
  /// resolved for each post's photo (the `media` bucket is private, so a
  /// plain public URL wouldn't be servable), plus like/comment counts.
  Future<List<Post>> fetchPage(
    int page, {
    required String currentUserId,
  }) async {
    final from = page * pageSize;
    final to = from + pageSize - 1;
    final rows = await _client
        .from('posts')
        .select('*, author:users(name)')
        .order('created_at', ascending: false)
        .range(from, to);

    var posts = rows.map(Post.fromRow).toList();
    if (posts.isEmpty) return posts;

    final postIds = posts.map((p) => p.id).toList();

    final reactionRows = await _client
        .from('reactions')
        .select('post_id, user_id')
        .inFilter('post_id', postIds);
    final commentRows = await _client
        .from('comments')
        .select('post_id')
        .inFilter('post_id', postIds);

    final likeCounts = <String, int>{};
    final likedByMe = <String>{};
    for (final row in reactionRows) {
      final postId = row['post_id'] as String;
      likeCounts[postId] = (likeCounts[postId] ?? 0) + 1;
      if (row['user_id'] == currentUserId) likedByMe.add(postId);
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
            likedByMe: likedByMe.contains(post.id),
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

  Future<void> like({required String postId, required String userId}) async {
    await _client.from('reactions').insert({
      'post_id': postId,
      'user_id': userId,
    });
  }

  Future<void> unlike({required String postId, required String userId}) async {
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
}

final feedRepositoryProvider = Provider<FeedRepository>((ref) {
  return FeedRepository(ref.watch(supabaseClientProvider));
});
