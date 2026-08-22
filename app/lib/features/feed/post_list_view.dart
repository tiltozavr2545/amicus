import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_localizations.dart';
import '../auth/auth_providers.dart';
import 'carousel_position_cache.dart';
import 'comments_screen.dart';
import 'create_post_screen.dart';
import 'feed_cache.dart';
import 'feed_repository.dart';

/// A paginated, pull-to-refresh list of posts, optionally scoped to a single
/// author. Shared by [FeedScreen] (all connections, [authorId] null) and the
/// profile screen's "my posts" section ([authorId] the current user).
class PostListView extends ConsumerStatefulWidget {
  const PostListView({super.key, this.authorId, this.emptyState, this.header});

  /// When set, only posts by this author are shown. When null, shows the
  /// full feed (subject to RLS visibility rules).
  final String? authorId;

  /// Rendered instead of the default "no posts" message when the list is
  /// empty and there is no error.
  final WidgetBuilder? emptyState;

  /// Scrolled together with the posts as this list's first item, rather than
  /// sitting in a separate scrollable above it — the profile screen uses this
  /// for its avatar/name section, so that content scrolls out of the way
  /// instead of permanently eating screen height above the post list.
  final Widget? header;

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

  // The viewer every cache entry this list touches is filed under. See
  // [FeedCache]: a page holds content RLS only ever showed to this account.
  String? _cacheUserId;

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
    // Captured once, here, rather than read inside each cache call: the
    // session can end while this list is still mounted (sign-out redirects
    // the router, it doesn't tear this widget down synchronously), and a save
    // that resolved `null` at that moment would file this viewer's page under
    // the signed-out slot.
    _cacheUserId = ref.read(currentUserIdProvider);
    _cacheLoadFuture = ref
        .read(feedCacheProvider)
        .load(_cacheUserId, widget.authorId);
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
        // `unawaited` silences the lint, not the failure: a rejected future
        // nobody is holding is an unhandled async error, and this one has a
        // plugin and a disk behind it. Writing the snapshot is best-effort by
        // construction — the page is already on screen, and this cache only
        // exists so the *next* cold start isn't blank — so a failed write has
        // to be swallowed here rather than escape into `FlutterError.onError`.
        unawaited(
          ref
              .read(feedCacheProvider)
              .save(_cacheUserId, widget.authorId, page)
              .catchError((Object _) {}),
        );
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

  // Takes the post itself, not its index. The callbacks below are built in
  // `itemBuilder` and then live inside the popup menu's own route, so they
  // outlive the list they were built against: `_loadMore` replaces `_posts`
  // wholesale on the first page (the cache preview being superseded by the
  // network page), and an index captured before that points at a different
  // post afterwards — or past the end. The write side already defended itself
  // by removing by id; the read on entry did not.
  Future<void> _deletePost(Post post) async {
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

  Future<void> _editPost(Post post) async {
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
  Future<void> _react(Post post, ReactionType type) async {
    final userId = ref.read(currentUserIdProvider);
    // The session can end while this list is still mounted — sign-out
    // redirects the router, it does not tear this widget down synchronously.
    // A tap landing in that window has nobody to attribute the reaction to.
    if (userId == null) return;
    final next = post.myReaction == type ? null : type;
    final at = _posts.indexWhere((p) => p.id == post.id);
    if (at == -1) return;
    setState(() => _posts[at] = applyReaction(post, next));
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

    final header = widget.header;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: _posts.isEmpty && !_isLoading
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                if (header != null) header,
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(_errorMessage!),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
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
              itemCount: _posts.length + 1 + (header != null ? 1 : 0),
              separatorBuilder: (context, index) => const SizedBox(height: 16),
              itemBuilder: (context, index) {
                if (header != null) {
                  if (index == 0) return header;
                  index -= 1;
                }
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
                // Not `!`: the session can clear while this list is still
                // mounted (see initState), and a rebuild in that window would
                // otherwise throw a null-check error out of `build` — a red
                // screen instead of a clean bounce to sign-in. No id matches
                // no author, which is the right answer for "is this mine".
                final currentUserId = ref.read(currentUserIdProvider);
                return _PostCard(
                  post: post,
                  isOwnPost:
                      currentUserId != null && post.authorId == currentUserId,
                  onReact: (type) => _react(post, type),
                  onEdit: () => _editPost(post),
                  onDelete: () => _deletePost(post),
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
                child: _MediaCarousel(postId: post.id, media: post.media),
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

/// How many slides on either side of the current one are signed and built
/// ahead of the viewer. One is enough to make a swipe feel instant — the
/// neighbour's URL is already signed and, thanks to `allowImplicitScrolling`,
/// its image is already downloading before the swipe starts — without paying
/// for slides nobody asked for.
const _prefetchRadius = 1;

/// The slides within [_prefetchRadius] of [index] that still need a signed
/// URL and aren't already being fetched. Marks what it returns as in flight
/// in [resolving]; the caller clears them when the batch settles.
List<int> _takePendingAround(
  List<PostMedia> items,
  int index,
  Set<int> resolving,
) {
  final pending = <int>[];
  for (var i = index - _prefetchRadius; i <= index + _prefetchRadius; i++) {
    if (i < 0 || i >= items.length) continue;
    if (!_needsResolving(items[i])) continue;
    if (!resolving.add(i)) continue;
    pending.add(i);
  }
  return pending;
}

bool _needsResolving(PostMedia item) =>
    item.url == null || (item.posterPath != null && item.posterUrl == null);

/// Every storage path the given slides are still missing a URL for — a video
/// contributes both its own path and its poster's.
List<String> _pathsToSign(List<PostMedia> items, Iterable<int> indices) {
  final paths = <String>[];
  for (final i in indices) {
    final item = items[i];
    if (item.url == null) paths.add(item.storagePath);
    final posterPath = item.posterPath;
    if (posterPath != null && item.posterUrl == null) paths.add(posterPath);
  }
  return paths;
}

/// [items] with the freshly signed URLs filled in. Paths missing from
/// [signedByPath] (the storage API refused to sign them) leave their slide
/// untouched, so it stays pending and is retried on the next swipe.
List<PostMedia> _applySignedUrls(
  List<PostMedia> items,
  Iterable<int> indices,
  Map<String, String> signedByPath,
) {
  final updated = List.of(items);
  for (final i in indices) {
    final item = updated[i];
    final posterPath = item.posterPath;
    updated[i] = item.copyWith(
      url: item.url ?? signedByPath[item.storagePath],
      posterUrl: posterPath == null
          ? item.posterUrl
          : item.posterUrl ?? signedByPath[posterPath],
    );
  }
  return updated;
}

/// A post's up-to-20 photos/videos, swiped horizontally one at a time
/// (Instagram-style), with a position counter when there's more than one.
///
/// Only the first item arrives with a resolved signed URL (see
/// [FeedRepository.fetchPage] — resolving all 20 for every post on every page
/// load would be wasteful for slides most viewers never swipe to), so this
/// widget signs the rest itself, a [_prefetchRadius]-wide window at a time so
/// the next slide is ready before the viewer swipes to it rather than only
/// starting to load once they have.
///
/// Which slide the viewer left off on is remembered in
/// [CarouselPositionCache] for as long as the app runs, so scrolling the post
/// out of the list and back doesn't rewind it to the first photo.
class _MediaCarousel extends ConsumerStatefulWidget {
  const _MediaCarousel({required this.postId, required this.media});

  final String postId;
  final List<PostMedia> media;

  @override
  ConsumerState<_MediaCarousel> createState() => _MediaCarouselState();
}

class _MediaCarouselState extends ConsumerState<_MediaCarousel> {
  late PageController _pageController;

  // Seeded from `widget.media`, then owned locally so [_resolveAround] can
  // fill in signed URLs the parent never learns about. That local ownership
  // is why [didUpdateWidget] below is not optional: build() reads `_items`, so
  // without it a State reused for a *different* post keeps painting the old
  // post's media under the new post's name.
  late List<PostMedia> _items = widget.media;
  final _resolving = <int>{};
  int _currentIndex = 0;

  // Bumped whenever `_items` is replaced wholesale from a new widget. A
  // resolve started against the previous post finishes with an item that no
  // longer belongs in this list, so it has to be able to tell it lost the
  // race — the `_resolving` set alone can't, it keys on an index that both
  // lists have.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = _rememberedIndex();
    _pageController = PageController(initialPage: _currentIndex);
    _resolveAround(_currentIndex);
  }

  @override
  void didUpdateWidget(covariant _MediaCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.postId == widget.postId &&
        _sameMedia(oldWidget.media, widget.media)) {
      return;
    }
    // A different post (or the same post's media edited): drop everything
    // derived from the old list, including any in-flight resolve.
    _generation++;
    _resolving.clear();
    _items = widget.media;
    _currentIndex = _rememberedIndex();
    // A fresh controller rather than `jumpToPage`, which needs one already
    // attached to a viewport — not the case when this very rebuild is what
    // introduces the PageView (a single-item post edited into a multi-item
    // one). The outgoing controller is still attached to the old viewport
    // until the rebuild that follows detaches it, hence disposing it a frame
    // later instead of here.
    final stale = _pageController;
    WidgetsBinding.instance.addPostFrameCallback((_) => stale.dispose());
    _pageController = PageController(initialPage: _currentIndex);
    _resolveAround(_currentIndex);
  }

  /// The slide this post was last left on, clamped: the media may have been
  /// edited down to fewer items since the position was recorded.
  int _rememberedIndex() {
    final cache = ref.read(carouselPositionCacheProvider);
    final remembered = cache.read(widget.postId);
    if (remembered == null || widget.media.isEmpty) return 0;
    return remembered.clamp(0, widget.media.length - 1);
  }

  /// Whether two media lists describe the same slides. Compared by row id and
  /// order rather than by list identity: `Post.copyWith` (reactions, comment
  /// counts) hands back the very same `List` instance, and rebuilding for that
  /// must not throw away URLs already resolved.
  static bool _sameMedia(List<PostMedia> a, List<PostMedia> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Signs [index] and its neighbours in one round trip.
  Future<void> _resolveAround(int index) async {
    final pending = _takePendingAround(_items, index, _resolving);
    if (pending.isEmpty) return;
    final generation = _generation;
    final repo = ref.read(feedRepositoryProvider);
    try {
      final signed = await repo.resolveMediaUrls(_pathsToSign(_items, pending));
      if (!mounted || generation != _generation) return;
      setState(() => _items = _applySignedUrls(_items, pending, signed));
    } catch (_) {
      // Offline, or the request timed out. The slides stay on their spinner
      // and, since the `finally` below un-marks them, are retried the next
      // time the viewer swipes near them — there is nothing to report here
      // that the missing photo doesn't already say.
    } finally {
      if (generation == _generation) _resolving.removeAll(pending);
    }
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    ref.read(carouselPositionCacheProvider).write(widget.postId, index);
    _resolveAround(index);
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
              // Keeps the slide on either side of the current one in the
              // tree, so its image is already downloading (and decoded, if it
              // has been seen before) by the time the swipe lands, instead of
              // starting from a spinner once the page has settled.
              allowImplicitScrolling: true,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, index) => _MediaSlide(
                item: _items[index],
                fit: BoxFit.cover,
                constrainHeight: true,
                isCurrent: index == _currentIndex,
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
  late int _currentIndex = widget.initialIndex;

  @override
  void initState() {
    super.initState();
    _resolveAround(widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Same one-round-trip window as the carousel's: the neighbouring photo is
  /// signed and loading before it's swiped to, not after.
  Future<void> _resolveAround(int index) async {
    final pending = _takePendingAround(_items, index, _resolving);
    if (pending.isEmpty) return;
    final repo = ref.read(feedRepositoryProvider);
    try {
      final signed = await repo.resolveMediaUrls(_pathsToSign(_items, pending));
      if (!mounted) return;
      setState(() => _items = _applySignedUrls(_items, pending, signed));
    } catch (_) {
      // Nothing to say beyond the spinner already on screen; un-marked below
      // so the next swipe retries.
    } finally {
      _resolving.removeAll(pending);
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
        allowImplicitScrolling: true,
        // Tracks the page as well as resolving around it: the same
        // keep-the-neighbour-alive behaviour as the carousel, so a video
        // swiped past here needs pausing for the same reason (see
        // [_MediaSlide.isCurrent]).
        onPageChanged: (index) {
          setState(() => _currentIndex = index);
          _resolveAround(index);
        },
        itemBuilder: (context, index) {
          final item = _items[index];
          if (item.mediaType == MediaType.video) {
            return Center(
              child: _MediaSlide(
                item: item,
                fit: BoxFit.contain,
                constrainHeight: false,
                isCurrent: index == _currentIndex,
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
    this.isCurrent = true,
    this.onTapImage,
  });

  final PostMedia item;
  final BoxFit fit;

  /// Whether this is the slide the viewer is actually looking at.
  ///
  /// It exists because of `allowImplicitScrolling`: the page on either side of
  /// the current one is deliberately kept in the tree so its image is already
  /// downloading before the swipe lands. For an image that is free; for a
  /// *playing video* it meant the clip was neither disposed nor paused when it
  /// was swiped past, so its audio went on playing over the next photo until
  /// the viewer swiped two slides away (or scrolled the whole post off screen)
  /// and the state was finally torn down.
  ///
  /// Losing this flag pauses rather than disposes, so swiping back resumes
  /// where the clip left off instead of restarting it.
  final bool isCurrent;

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
  void didUpdateWidget(covariant _MediaSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    // build() short-circuits on a non-null controller, so a State reused for
    // a different item would keep rendering (and playing) the previous clip
    // under the new one. Only the *identity* of the media matters here — a
    // rebuild that merely filled in a resolved URL for the same row must not
    // interrupt playback.
    if (oldWidget.item.id == widget.item.id) {
      // Same clip, but it is no longer the page in view — see [isCurrent].
      final controller = _controller;
      if (controller != null && oldWidget.isCurrent && !widget.isCurrent) {
        unawaited(controller.pause().catchError((Object _) {}));
      }
      return;
    }
    final stale = _controller;
    _controller = null;
    stale?.dispose();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    final url = widget.item.url;
    if (url == null) return;
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await controller.initialize();
    } catch (_) {
      // An unplayable codec, an expired signed URL, no network. Nothing to
      // report beyond leaving the poster and its play button in place —
      // letting this escape would be an unhandled async error *and* would
      // leak the controller, since dispose() only ever runs via State.
      await controller.dispose();
      return;
    }
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
