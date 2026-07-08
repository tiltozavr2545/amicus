import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../auth/auth_providers.dart';
import 'comments_screen.dart';
import 'create_post_screen.dart';
import 'feed_repository.dart';

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  final _scrollController = ScrollController();
  final _posts = <Post>[];
  int _nextPage = 0;
  bool _isLoading = false;
  bool _hasMore = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _scrollController.addListener(() {
      final nearBottom =
          _scrollController.position.pixels >
          _scrollController.position.maxScrollExtent - 200;
      if (nearBottom) _loadMore();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_isLoading || !_hasMore) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final userId = ref.read(supabaseClientProvider).auth.currentUser!.id;
      final page = await ref
          .read(feedRepositoryProvider)
          .fetchPage(_nextPage, currentUserId: userId);
      setState(() {
        _posts.addAll(page);
        _nextPage++;
        _hasMore = page.length == pageSize;
      });
    } catch (e) {
      setState(() => _errorMessage = 'Не удалось загрузить ленту: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _posts.clear();
      _nextPage = 0;
      _hasMore = true;
    });
    await _loadMore();
  }

  Future<void> _toggleLike(int index) async {
    final post = _posts[index];
    final userId = ref.read(supabaseClientProvider).auth.currentUser!.id;
    final wasLiked = post.likedByMe;
    setState(() {
      _posts[index] = post.copyWith(
        likedByMe: !wasLiked,
        likeCount: post.likeCount + (wasLiked ? -1 : 1),
      );
    });
    try {
      final repo = ref.read(feedRepositoryProvider);
      if (wasLiked) {
        await repo.unlike(postId: post.id, userId: userId);
      } else {
        await repo.like(postId: post.id, userId: userId);
      }
    } catch (_) {
      if (mounted) setState(() => _posts[index] = post);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Amicus'),
        actions: [
          IconButton(
            icon: const Icon(Icons.people_outline),
            tooltip: 'Знакомства',
            onPressed: () => context.push('/connections'),
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Профиль',
            onPressed: () => context.push('/profile'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final created = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const CreatePostScreen()),
          );
          if (created == true) _refresh();
        },
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _posts.isEmpty && !_isLoading
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_errorMessage!),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          const Text(
                            'Пока нет постов от знакомых. Добавь знакомых или напиши первым.',
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: () => context.push('/connections'),
                            child: const Text('Добавить знакомых'),
                          ),
                        ],
                      ),
                    ),
                ],
              )
            : ListView.separated(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                itemCount: _posts.length + 1,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 16),
                itemBuilder: (context, index) {
                  if (index == _posts.length) {
                    return _hasMore
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: CircularProgressIndicator(),
                            ),
                          )
                        : const SizedBox.shrink();
                  }
                  final post = _posts[index];
                  return _PostCard(
                    post: post,
                    onToggleLike: () => _toggleLike(index),
                    onOpenComments: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CommentsScreen(postId: post.id),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({
    required this.post,
    required this.onToggleLike,
    required this.onOpenComments,
  });

  final Post post;
  final VoidCallback onToggleLike;
  final VoidCallback onOpenComments;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              post.authorName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              DateFormat('d MMM y, HH:mm').format(post.createdAt),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (post.text != null) ...[
              const SizedBox(height: 8),
              Text(post.text!),
            ],
            if (post.imageUrl != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: post.imageUrl!,
                  fit: BoxFit.cover,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    post.likedByMe ? Icons.favorite : Icons.favorite_border,
                  ),
                  color: post.likedByMe ? Colors.red : null,
                  onPressed: onToggleLike,
                ),
                Text('${post.likeCount}'),
                const SizedBox(width: 16),
                IconButton(
                  icon: const Icon(Icons.mode_comment_outlined),
                  onPressed: onOpenComments,
                ),
                Text('${post.commentCount}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
