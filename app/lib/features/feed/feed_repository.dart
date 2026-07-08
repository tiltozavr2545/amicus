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
  });

  final String id;
  final String authorId;
  final String authorName;
  final DateTime createdAt;
  final String? text;
  final String? imageUrl;

  factory Post.fromRow(Map<String, dynamic> row) {
    return Post(
      id: row['id'] as String,
      authorId: row['author_id'] as String,
      authorName: (row['author'] as Map<String, dynamic>)['name'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      text: row['text'] as String?,
    );
  }
}

const _bucket = 'media';
const pageSize = 20;

class FeedRepository {
  FeedRepository(this._client);

  final SupabaseClient _client;

  /// Fetches one page of the feed (newest first), with a signed URL
  /// resolved for each post's photo — the `media` bucket is private, so a
  /// plain public URL wouldn't be servable.
  Future<List<Post>> fetchPage(int page) async {
    final from = page * pageSize;
    final to = from + pageSize - 1;
    final rows = await _client
        .from('posts')
        .select('*, author:users(name)')
        .order('created_at', ascending: false)
        .range(from, to);

    return Future.wait(
      rows.map((row) async {
        final post = Post.fromRow(row);
        final path = row['image_path'] as String?;
        if (path == null) return post;
        final url = await _client.storage
            .from(_bucket)
            .createSignedUrl(path, 60 * 60 * 24);
        return Post(
          id: post.id,
          authorId: post.authorId,
          authorName: post.authorName,
          createdAt: post.createdAt,
          text: post.text,
          imageUrl: url,
        );
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
}

final feedRepositoryProvider = Provider<FeedRepository>((ref) {
  return FeedRepository(ref.watch(supabaseClientProvider));
});
