import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../auth/auth_providers.dart';
import 'comments_screen.dart';
import 'feed_cache.dart';
import 'feed_repository.dart';

/// A paginated, pull-to-refresh list of posts, optionally scoped to a single
/// author. Shared by [FeedScreen] (all connections, [authorId] null) and the
/// profile screen's "my posts" section ([authorId] the current user).
class PostListView extends ConsumerStatefulWidget {
  const PostListView({super.key, this.authorId, this.emptyState});

  /// When set, only posts by this author are shown. When null, shows the
  /// full feed (subject to RLS visibility rules).
  final String? authorId;

  /// Rendered instead of the default "no posts" message when the list is
  /// empty and there is no error.
  final WidgetBuilder? emptyState;

  @override
  ConsumerState<PostListView> createState() => _PostListViewState();
}

class _PostListViewState extends ConsumerState<PostListView> {
  final _scrollController = ScrollController();
  final _posts = <Post>[];

  // The keyset cursor for the next page, tracked separately from `_posts`
  // rather than derived from its last element: `_posts` may start out primed
  // with a cached preview (see [_primeFromCache]), and that preview must
  // never be mistaken for an already-fetched page — the first real fetch
  // always has to ask the server for page one.
  Post? _cursor;
  bool _isLoading = false;
  bool _hasMore = true;
  String? _errorMessage;

  // Started once in initState and awaited from both [_primeFromCache] (an
  // instant preview) and [_loadMore]'s failure path (a fallback if the fetch
  // loses that race). A single shared read — rather than each side issuing
  // its own — means the two can never disagree about what was cached or
  // apply it twice.
  late final Future<List<Post>?> _cacheLoadFuture;

  // Set once the very first fetch attempt (success or failure) has settled,
  // so a cache read that resolves after it can no longer touch `_posts` —
  // including when the real fetch came back with zero posts: that confirmed
  // "nothing to show", and a stale cached page must not overwrite it.
  bool _firstFetchSettled = false;

  // Bumped on every refresh so a page load that's still in flight when the user
  // pulls to refresh can detect it's stale and discard its result instead of
  // appending it onto the freshly-cleared list.
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    _cacheLoadFuture = ref.read(feedCacheProvider).load(widget.authorId);
    _primeFromCache();
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

  /// Shows the last-seen page for this scope (see [FeedCache]) immediately,
  /// before the real fetch below completes — and keeps showing it if that
  /// fetch never succeeds because there's no connection.
  Future<void> _primeFromCache() async {
    final cached = await _cacheLoadFuture;
    if (!mounted || _firstFetchSettled || cached == null || cached.isEmpty) {
      return;
    }
    setState(() => _posts.addAll(cached));
  }

  Future<void> _loadMore() async {
    if (_isLoading || !_hasMore) return;
    final epoch = _loadEpoch;
    final isFirstPage = _cursor == null;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final page = await ref
          .read(feedRepositoryProvider)
          .fetchPage(cursor: _cursor, authorId: widget.authorId);
      // A refresh (or unmount) happened while this page was loading — its data
      // is for a superseded feed state, so drop it.
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        if (isFirstPage) {
          // Replaces rather than appends: `_posts` may hold a cache preview
          // (or, on a pull-to-refresh, the previous live page) that this
          // fresh page one supersedes outright.
          _posts
            ..clear()
            ..addAll(page);
        } else {
          _posts.addAll(page);
        }
        if (page.isNotEmpty) _cursor = page.last;
        _hasMore = page.length == pageSize;
      });
      if (isFirstPage) {
        unawaited(ref.read(feedCacheProvider).save(widget.authorId, page));
      }
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      if (isFirstPage && _posts.isEmpty) {
        // Nothing on screen yet — [_primeFromCache] may simply not have
        // resolved yet. Wait on the same cache read rather than issuing a
        // second one, so the decision below sees its result either way.
        final cached = await _cacheLoadFuture;
        if (!mounted || epoch != _loadEpoch) return;
        if (_posts.isEmpty && cached != null && cached.isNotEmpty) {
          setState(() => _posts.addAll(cached));
        }
      }
      if (_posts.isEmpty) {
        setState(
          () => _errorMessage = AppLocalizations.of(
            context,
          )!.failedToLoadFeedError,
        );
      } else {
        // Something is on screen — a cached page (just found above, or by
        // [_primeFromCache] beforehand), or an earlier successful load — so
        // don't blank it out from under the user over a failed refresh;
        // report it without discarding what's shown.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.failedToLoadFeedError),
          ),
        );
      }
    } finally {
      if (mounted && epoch == _loadEpoch) {
        setState(() {
          _isLoading = false;
          _firstFetchSettled = true;
        });
      }
    }
  }

  Future<void> _refresh() async {
    setState(() {
      // Invalidate any in-flight load and reset paging from scratch. Not
      // clearing `_posts` up front means an offline pull-to-refresh falls
      // back to the "keep what's on screen" branch above instead of wiping
      // the feed out and showing an error. Clearing _isLoading lets the fresh
      // load below start even if one was running.
      _loadEpoch++;
      _cursor = null;
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.failedToDeletePostError)));
      }
    }
  }

  /// Tapping a reaction toggles it: tapping the one you already have clears it,
  /// tapping a different one switches to it. Applied optimistically, rolled
  /// back on error.
  Future<void> _react(int index, ReactionType type) async {
    final post = _posts[index];
    final userId = ref.read(currentUserIdProvider)!;
    final next = post.myReaction == type ? null : type;
    setState(() => _posts[index] = applyReaction(post, next));
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

  @override
  Widget build(BuildContext context) {
    // A post created from the bottom-nav "new post" tab, or a mute/block
    // change, bumps this counter so any open list refreshes itself.
    ref.listen<int>(feedRefreshTickProvider, (previous, next) {
      if (previous != null) _refresh();
    });
    final l10n = AppLocalizations.of(context)!;

    return RefreshIndicator(
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
                    child:
                        widget.emptyState?.call(context) ??
                        Column(children: [Text(l10n.noPostsYetMessage)]),
                  ),
              ],
            )
          : ListView.separated(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: _posts.length + 1,
              separatorBuilder: (context, index) => const SizedBox(height: 16),
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
                final currentUserId = ref.read(currentUserIdProvider)!;
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
                  // The URL is a signed Storage link that gets re-signed
                  // (different query string) on every fetch, which would
                  // otherwise cache-bust on every app restart even though the
                  // underlying photo hasn't changed. Keying on the storage
                  // path instead — stable for the life of the post today,
                  // and the thing that would actually change if post editing
                  // ever lets a photo be replaced — means a previously seen
                  // photo paints from disk instantly instead of behind a
                  // fresh download.
                  cacheKey: post.imagePath,
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
