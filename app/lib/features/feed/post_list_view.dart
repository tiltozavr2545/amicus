import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_localizations.dart';
import '../auth/auth_providers.dart';
import 'comments_screen.dart';
import 'create_post_screen.dart';
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
      final mediaPaths = [
        for (final media in post.media) media.storagePath,
        for (final media in post.media)
          if (media.posterPath != null) media.posterPath!,
      ];
      await ref
          .read(feedRepositoryProvider)
          .deletePost(postId: post.id, mediaStoragePaths: mediaPaths);
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

  Future<void> _editPost(int index) async {
    final post = _posts[index];
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CreatePostScreen(existingPost: post)),
    );
    // The post's text/media may have changed — simplest correct thing is to
    // let the same refresh path a newly created post already triggers pick
    // the edited version back up, rather than reconstructing it locally.
    if (saved == true) {
      ref.read(feedRefreshTickProvider.notifier).bump();
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
    // A post created from the bottom-nav "new post" tab, an edit saved from a
    // post's own menu, or a mute/block change, bumps this counter so any open
    // list refreshes itself.
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
                  onEdit: () => _editPost(index),
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
    required this.onEdit,
    required this.onDelete,
    required this.onOpenComments,
  });

  final Post post;
  final bool isOwnPost;
  final ValueChanged<ReactionType> onReact;
  final VoidCallback onEdit;
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
                        onTap: onEdit,
                        child: Text(l10n.editButton),
                      ),
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
            if (post.media.isNotEmpty) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _MediaCarousel(media: post.media),
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

/// A post's up-to-20 photos/videos, swiped horizontally one at a time
/// (Instagram-style), with a position counter when there's more than one.
///
/// Only the first item arrives with a resolved signed URL (see
/// [FeedRepository.fetchPage] — resolving all 20 for every post on every page
/// load would be wasteful for slides most viewers never swipe to), so this
/// widget resolves each further slide lazily, right before it's shown.
class _MediaCarousel extends ConsumerStatefulWidget {
  const _MediaCarousel({required this.media});

  final List<PostMedia> media;

  @override
  ConsumerState<_MediaCarousel> createState() => _MediaCarouselState();
}

class _MediaCarouselState extends ConsumerState<_MediaCarousel> {
  late final _pageController = PageController();
  late List<PostMedia> _items = widget.media;
  final _resolving = <int>{};
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _resolve(0);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _resolve(int index) async {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    final needsUrl = item.url == null;
    final needsPosterUrl = item.posterPath != null && item.posterUrl == null;
    if (!needsUrl && !needsPosterUrl) return;
    if (!_resolving.add(index)) return;
    final repo = ref.read(feedRepositoryProvider);
    try {
      final url = needsUrl
          ? await repo.resolveMediaUrl(item.storagePath)
          : item.url;
      final posterPath = item.posterPath;
      final posterUrl = needsPosterUrl
          ? await repo.resolveMediaUrl(posterPath!)
          : item.posterUrl;
      if (!mounted) return;
      setState(() {
        _items = List.of(_items)
          ..[index] = item.copyWith(url: url, posterUrl: posterUrl);
      });
    } finally {
      _resolving.remove(index);
    }
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    _resolve(index);
  }

  void _openFullscreen(int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            _FullscreenMediaViewer(media: _items, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A lone photo/video is shown at its own natural size — no forced box, no
    // crop, exactly like a single-photo post always has been. A fixed frame
    // only becomes necessary once there's more than one slide to swipe
    // between (see below).
    if (_items.length == 1) {
      return _MediaSlide(
        item: _items[0],
        fit: BoxFit.cover,
        constrainHeight: false,
        onTapImage: () => _openFullscreen(0),
      );
    }

    // With several items of possibly different aspect ratios, the carousel
    // needs one fixed frame so the card's height doesn't jump as the user
    // swipes — otherwise every slide change would reflow the whole feed list
    // under it. 4:5 mirrors the box Instagram settled on for the same
    // problem. `cover` inside that fixed frame does crop the preview, but a
    // tap always opens the untouched original via [_openFullscreen].
    return AspectRatio(
      aspectRatio: 4 / 5,
      child: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _pageController,
              itemCount: _items.length,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, index) => _MediaSlide(
                item: _items[index],
                fit: BoxFit.cover,
                constrainHeight: true,
                onTapImage: () => _openFullscreen(index),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${_currentIndex + 1}/${_items.length}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen, pinch-zoomable, swipeable view of every media item on a post
/// — opened by tapping a photo, so a carousel's `cover`-cropped preview never
/// costs the viewer the actual, untouched photo. Videos inside it reuse
/// [_MediaSlide]'s own tap-to-play behaviour rather than getting a zoom
/// gesture, which wouldn't mean anything for a video anyway.
class _FullscreenMediaViewer extends ConsumerStatefulWidget {
  const _FullscreenMediaViewer({
    required this.media,
    required this.initialIndex,
  });

  final List<PostMedia> media;
  final int initialIndex;

  @override
  ConsumerState<_FullscreenMediaViewer> createState() =>
      _FullscreenMediaViewerState();
}

class _FullscreenMediaViewerState
    extends ConsumerState<_FullscreenMediaViewer> {
  late final _pageController = PageController(initialPage: widget.initialIndex);
  late List<PostMedia> _items = widget.media;
  final _resolving = <int>{};

  @override
  void initState() {
    super.initState();
    _resolve(widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _resolve(int index) async {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    final needsUrl = item.url == null;
    final needsPosterUrl = item.posterPath != null && item.posterUrl == null;
    if (!needsUrl && !needsPosterUrl) return;
    if (!_resolving.add(index)) return;
    final repo = ref.read(feedRepositoryProvider);
    try {
      final url = needsUrl
          ? await repo.resolveMediaUrl(item.storagePath)
          : item.url;
      final posterPath = item.posterPath;
      final posterUrl = needsPosterUrl
          ? await repo.resolveMediaUrl(posterPath!)
          : item.posterUrl;
      if (!mounted) return;
      setState(() {
        _items = List.of(_items)
          ..[index] = item.copyWith(url: url, posterUrl: posterUrl);
      });
    } finally {
      _resolving.remove(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: _items.length,
        onPageChanged: _resolve,
        itemBuilder: (context, index) {
          final item = _items[index];
          if (item.mediaType == MediaType.video) {
            return Center(
              child: _MediaSlide(
                item: item,
                fit: BoxFit.contain,
                constrainHeight: false,
              ),
            );
          }
          return item.url == null
              ? const Center(child: CircularProgressIndicator())
              : InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Center(
                    child: CachedNetworkImage(
                      imageUrl: item.url!,
                      cacheKey: item.storagePath,
                      fit: BoxFit.contain,
                    ),
                  ),
                );
        },
      ),
    );
  }
}

/// One slide of [_MediaCarousel]: a plain image, or a video that starts out as
/// a poster with a play affordance and only becomes an actual
/// [VideoPlayerController] once tapped — never autoplaying while scrolled
/// into view, per the feed's tap-to-play behaviour. Its own [State] so the
/// controller is created (and disposed, when the user swipes away and this
/// widget leaves the tree) per slide rather than per post.
class _MediaSlide extends StatefulWidget {
  const _MediaSlide({
    required this.item,
    required this.fit,
    required this.constrainHeight,
    this.onTapImage,
  });

  final PostMedia item;
  final BoxFit fit;

  /// Whether this slide sits inside a fixed-height frame (the multi-item
  /// carousel, or the fullscreen viewer's own bounded page) — an image only
  /// needs `width: double.infinity` for the fixed-frame case; left off
  /// otherwise so it can size itself to its own natural aspect ratio instead
  /// of stretching to fill an unrelated width.
  final bool constrainHeight;

  /// Opens the fullscreen viewer. Null (or ignored, for video — tapping a
  /// video slide always means play/pause, never zoom) when there's nothing
  /// to expand to.
  final VoidCallback? onTapImage;

  @override
  State<_MediaSlide> createState() => _MediaSlideState();
}

class _MediaSlideState extends State<_MediaSlide> {
  VideoPlayerController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    final url = widget.item.url;
    if (url == null) return;
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
    await controller.play();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (item.mediaType == MediaType.image) {
      final image = item.url == null
          ? const Center(child: CircularProgressIndicator())
          : CachedNetworkImage(
              imageUrl: item.url!,
              // The URL is a signed Storage link that gets re-signed
              // (different query string) on every fetch, which would
              // otherwise cache-bust every time even though the underlying
              // photo hasn't changed. Keying on the storage path instead —
              // stable for the object's whole lifetime — means a
              // previously seen photo paints from disk instantly.
              cacheKey: item.storagePath,
              fit: widget.fit,
              width: widget.constrainHeight ? double.infinity : null,
            );
      final onTapImage = widget.onTapImage;
      return onTapImage == null
          ? image
          : GestureDetector(onTap: onTapImage, child: image);
    }

    final controller = _controller;
    if (controller != null) {
      return GestureDetector(
        onTap: () => setState(() {
          controller.value.isPlaying ? controller.pause() : controller.play();
        }),
        child: Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: VideoPlayer(controller),
          ),
        ),
      );
    }

    final poster = Stack(
      fit: StackFit.expand,
      children: [
        if (item.posterUrl != null)
          CachedNetworkImage(
            imageUrl: item.posterUrl!,
            cacheKey: item.posterPath,
            fit: BoxFit.cover,
          )
        else
          const ColoredBox(color: Colors.black12),
        Center(
          child: IconButton(
            iconSize: 56,
            color: Colors.white,
            icon: const Icon(Icons.play_circle_fill),
            tooltip: AppLocalizations.of(context)!.playVideoTooltip,
            onPressed: item.url == null ? null : _play,
          ),
        ),
      ],
    );
    // `StackFit.expand` needs a parent that hands it a bounded, finite size —
    // true inside the carousel's fixed frame, but not for a lone video post
    // sitting straight in the feed's unconstrained-height column. There's no
    // real aspect ratio to fall back on before the video itself is decoded
    // (only the poster image, whose intrinsic size isn't known synchronously
    // either), so a lone video poster settles for the same 4:5 box the
    // multi-item carousel already uses, rather than crashing the layout.
    return widget.constrainHeight
        ? poster
        : AspectRatio(aspectRatio: 4 / 5, child: poster);
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
