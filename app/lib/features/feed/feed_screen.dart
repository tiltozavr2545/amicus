import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme_toggle_switch.dart';
import '../auth/auth_providers.dart';
import 'comments_screen.dart';
import 'feed_repository.dart';

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  final _scrollController = ScrollController();
  final _posts = <Post>[];
  bool _isLoading = false;
  bool _hasMore = true;
  String? _errorMessage;

  // Bumped on every refresh so a page load that's still in flight when the user
  // pulls to refresh can detect it's stale and discard its result instead of
  // appending it onto the freshly-cleared list.
  int _loadEpoch = 0;

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
    final epoch = _loadEpoch;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      // The last post already loaded is the keyset cursor for the next page
      // (null on the first/refreshed load). Captured before the await, so a
      // concurrent refresh can't move it mid-flight.
      final cursor = _posts.isEmpty ? null : _posts.last;
      final page = await ref
          .read(feedRepositoryProvider)
          .fetchPage(cursor: cursor);
      // A refresh (or unmount) happened while this page was loading — its data
      // is for a superseded feed state, so drop it.
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _posts.addAll(page);
        _hasMore = page.length == pageSize;
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(
        () => _errorMessage = AppLocalizations.of(
          context,
        )!.failedToLoadFeedError(e),
      );
    } finally {
      if (mounted && epoch == _loadEpoch) setState(() => _isLoading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      // Invalidate any in-flight load and reset paging from scratch. Clearing
      // _isLoading lets the fresh load below start even if one was running.
      _loadEpoch++;
      _posts.clear();
      _hasMore = true;
      _isLoading = false;
      _errorMessage = null;
    });
    await _loadMore();
  }

  Future<void> _deletePost(int index) async {
    final post = _posts[index];
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deletePostTitle),
        content: Text(l10n.deletePostContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref
          .read(feedRepositoryProvider)
          .deletePost(postId: post.id, imagePath: post.imagePath);
      // Remove by id, not the captured index: the list may have shifted (a
      // refresh, another delete) while the request was in flight.
      if (mounted) setState(() => _posts.removeWhere((p) => p.id == post.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.failedToDeletePostError(e))),
        );
      }
    }
  }

  /// Tapping a reaction toggles it: tapping the one you already have clears it,
  /// tapping a different one switches to it. Applied optimistically, rolled
  /// back on error.
  Future<void> _react(int index, ReactionType type) async {
    final post = _posts[index];
    final userId = ref.read(supabaseClientProvider).auth.currentUser!.id;
    final next = post.myReaction == type ? null : type;
    setState(() => _posts[index] = _applyReaction(post, next));
    try {
      final repo = ref.read(feedRepositoryProvider);
      if (next == null) {
        await repo.removeReaction(postId: post.id, userId: userId);
      } else {
        await repo.setReaction(postId: post.id, userId: userId, type: next);
      }
    } catch (_) {
      // Roll back by id, not the captured index: the list may have been
      // refreshed or had a post removed while the request was in flight.
      if (!mounted) return;
      final current = _posts.indexWhere((p) => p.id == post.id);
      if (current != -1) setState(() => _posts[current] = post);
    }
  }

  /// Returns [post] with its counts and `myReaction` adjusted from the current
  /// reaction to [next] (null = no reaction).
  Post _applyReaction(Post post, ReactionType? next) {
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

  @override
  Widget build(BuildContext context) {
    // A post created from the bottom-nav "new post" tab bumps this counter
    // (FeedScreen no longer owns the create-post entry point itself).
    ref.listen<int>(feedRefreshTickProvider, (previous, next) {
      if (previous != null) _refresh();
    });
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Amicus'),
        actions: const [ThemeToggleSwitch()],
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
                          Text(l10n.noPostsYetMessage),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: () => context.go('/connections'),
                            child: Text(l10n.addConnectionsButton),
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
                  final currentUserId = ref
                      .read(supabaseClientProvider)
                      .auth
                      .currentUser!
                      .id;
                  return _PostCard(
                    post: post,
                    isOwnPost: post.authorId == currentUserId,
                    onReact: (type) => _react(index, type),
                    onDelete: () => _deletePost(index),
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
    required this.isOwnPost,
    required this.onReact,
    required this.onDelete,
    required this.onOpenComments,
  });

  final Post post;
  final bool isOwnPost;
  final ValueChanged<ReactionType> onReact;
  final VoidCallback onDelete;
  final VoidCallback onOpenComments;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    post.authorName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (isOwnPost)
                  PopupMenuButton<void>(
                    icon: const Icon(Icons.more_vert),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        onTap: onDelete,
                        child: Text(l10n.deleteButton),
                      ),
                    ],
                  ),
              ],
            ),
            Text(
              DateFormat(
                'd MMM y, HH:mm',
                l10n.localeName,
              ).format(post.createdAt),
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
                _ReactionButton(
                  selectedIcon: Icons.thumb_up,
                  unselectedIcon: Icons.thumb_up_outlined,
                  color: Colors.green,
                  tooltip: l10n.likeTooltip,
                  count: post.likeCount,
                  selected: post.myReaction == ReactionType.like,
                  onPressed: () => onReact(ReactionType.like),
                ),
                _ReactionButton(
                  selectedIcon: Icons.sentiment_neutral,
                  unselectedIcon: Icons.sentiment_neutral_outlined,
                  color: Colors.amber,
                  tooltip: l10n.neutralTooltip,
                  count: post.neutralCount,
                  selected: post.myReaction == ReactionType.neutral,
                  onPressed: () => onReact(ReactionType.neutral),
                ),
                // Authors can opt out of negative reactions: hide the dislike
                // button under their posts. The database enforces the same rule,
                // so this stays a UI nicety rather than the actual guard.
                if (!post.authorDislikesDisabled)
                  _ReactionButton(
                    selectedIcon: Icons.thumb_down,
                    unselectedIcon: Icons.thumb_down_outlined,
                    color: Colors.red,
                    tooltip: l10n.dislikeTooltip,
                    count: post.dislikeCount,
                    selected: post.myReaction == ReactionType.dislike,
                    onPressed: () => onReact(ReactionType.dislike),
                  ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.mode_comment_outlined),
                  visualDensity: VisualDensity.compact,
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

class _ReactionButton extends StatelessWidget {
  const _ReactionButton({
    required this.selectedIcon,
    required this.unselectedIcon,
    required this.color,
    required this.tooltip,
    required this.count,
    required this.selected,
    required this.onPressed,
  });

  final IconData selectedIcon;
  final IconData unselectedIcon;
  final Color color;
  final String tooltip;
  final int count;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(selected ? selectedIcon : unselectedIcon),
          color: selected ? color : null,
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          onPressed: onPressed,
        ),
        Text('$count'),
      ],
    );
  }
}
