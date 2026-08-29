import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/media_gallery.dart';
import '../auth/auth_providers.dart';
import 'carousel_position_cache.dart';
import 'comments_screen.dart';
import 'create_post_screen.dart';
import 'feed_cache.dart';
import 'feed_repository.dart';

/// A paginated, pull-to-refresh list of posts, optionally scoped to a single
/// author. Shared by [FeedScreen] (all connections, scope null) and the
/// profile screen's "my posts" section ([authorId] the current user).
class PostListView extends ConsumerStatefulWidget {
  const PostListView({super.key, this.authorId, this.emptyState, this.header});

  /// When set, only posts by this author are shown. When null, shows the
  /// full feed (subject to RLS visibility rules).
  final String? authorId;

  /// Which slot in [FeedCache] this list's first page belongs to.
  String? get cacheScope => authorId;

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

  // Reaction taps on one post are not serialised — nothing stops a second tap
  // while the first request is still in flight — so a failure has to be able to
  // tell whether it is still the one that owns the card. These two maps are
  // what [_react] needs to answer that.
  //
  // `_reactionSeq` is the number of the newest request issued for a post: an
  // older one that fails must stay silent, or it repaints over a newer request
  // that has already succeeded.
  //
  // `_confirmedReaction` is the last reaction the *server* acknowledged for a
  // post (seeded from what was on screen at the first tap, when nothing was yet
  // in flight). Rolling back to it, rather than to a Post captured before the
  // tap, is what makes two failed taps in a row land back on the real state
  // instead of on the state between them.
  //
  // Both grow only for posts this session actually reacted to — a handful of
  // uuids — and are deliberately not cleared on refresh: a refresh that failed
  // offline leaves the optimistic values on screen, and re-seeding from those
  // would be worse than keeping what the server last confirmed.
  final _reactionSeq = <String, int>{};
  final _confirmedReaction = <String, ReactionType?>{};

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
        .load(_cacheUserId, widget.cacheScope);
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
              .save(_cacheUserId, widget.cacheScope, page)
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
      if (!mounted) return;
      // Remove by id, not the captured index: the list may have shifted (a
      // refresh, another delete) while the request was in flight.
      setState(() => _posts.removeWhere((p) => p.id == post.id));
      // Убрать из СВОЕГО списка мало. Живых PostListView одновременно
      // несколько: лента и профиль — две ветки shell'а в IndexedStack, плюс
      // FriendProfileScreen сверху. Удалили пост из профиля — во вкладке
      // ленты он остаётся, и остаётся кликабельным: реакцию по нему RLS
      // отбивает («Users can like posts they can see» требует существования
      // строки в posts), а [_react] эту ошибку молча откатывает, комментарии
      // открываются пустыми, повторное «Удалить» задевает ноль строк и
      // считается успехом.
      //
      // Ровно та несогласованность, ради которой заведён
      // [feedRefreshTickProvider] — и правка поста, и mute/block, и новый
      // пост через него уже проходят. Удаление было единственной мутацией
      // ленты, которая его не дёргала. Локальное removeWhere выше при этом
      // остаётся: оно убирает карточку сразу, не дожидаясь перезапроса.
      ref.read(feedRefreshTickProvider.notifier).bump();
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

  /// Ставит на карточку то число комментариев, которое [CommentsScreen] только
  /// что увидел у сервера.
  ///
  /// Без этого счётчик не менялся вообще никогда: экран комментариев
  /// открывался без `.then`, ничего не возвращал и тик обновления не дёргал,
  /// так что человек писал комментарий, возвращался — и видел прежнее число.
  /// Удаление своего комментария оставляло число завышенным. До первого
  /// pull-to-refresh.
  ///
  /// По id, а не по индексу, и с проверкой [mounted] — экран висит поверх
  /// списка сколько угодно долго, за это время список мог обновиться целиком
  /// или уехать вместе с вкладкой (та же причина, что у [_deletePost] и
  /// [_react]).
  void _updateCommentCount(String postId, int count) {
    if (!mounted) return;
    final at = _posts.indexWhere((p) => p.id == postId);
    if (at == -1) return;
    if (_posts[at].commentCount == count) return;
    setState(() => _posts[at] = _posts[at].copyWith(commentCount: count));
  }

  /// Tapping a reaction toggles it: tapping the one you already have clears it,
  /// tapping a different one switches to it. Applied optimistically, rolled
  /// back on error.
  ///
  /// The rollback is a *transition* applied to whatever is on screen now, not
  /// the restoration of a snapshot taken before the tap, and it only happens
  /// when this is still the newest request for the post. Restoring a snapshot
  /// was wrong on the path that matters most: `.timeout()` stops waiting
  /// without cancelling, so on a bad connection a tap regularly "fails" while a
  /// second one lands. 👍 then 👎, with the 👍 timing out, restored the state
  /// from before the 👍 — no reaction at all — while the server was holding the
  /// dislike the user could plainly see they had left. It stayed that way until
  /// the next pull-to-refresh.
  Future<void> _react(Post post, ReactionType type) async {
    final userId = ref.read(currentUserIdProvider);
    // The session can end while this list is still mounted — sign-out
    // redirects the router, it does not tear this widget down synchronously.
    // A tap landing in that window has nobody to attribute the reaction to.
    if (userId == null) return;
    final at = _posts.indexWhere((p) => p.id == post.id);
    if (at == -1) return;

    // The transition is read off the list, not off the captured [post]: a
    // card's callbacks are built once and then live inside the list item, so
    // [post] can be a frame behind — and "tapping the one you already have
    // clears it" gives the wrong answer the moment it is decided from a stale
    // reading.
    final shown = _posts[at];
    final next = shown.myReaction == type ? null : type;

    // Seeded at the first tap, while nothing is in flight — at that moment what
    // is on screen is what the server holds. After that only a confirmed
    // response moves it, which is what makes it a safe rollback target.
    _confirmedReaction.putIfAbsent(post.id, () => shown.myReaction);
    final seq = (_reactionSeq[post.id] ?? 0) + 1;
    _reactionSeq[post.id] = seq;

    setState(() => _posts[at] = applyReaction(shown, next));
    try {
      final repo = ref.read(feedRepositoryProvider);
      if (next == null) {
        await repo.removeReaction(postId: post.id, userId: userId);
      } else {
        await repo.setReaction(postId: post.id, userId: userId, type: next);
      }
      _confirmedReaction[post.id] = next;
    } catch (_) {
      if (!mounted) return;
      // Superseded: a newer tap owns the card now, and this request has no idea
      // what has happened since it went out. Staying quiet is the whole fix.
      if (_reactionSeq[post.id] != seq) return;
      // Roll back by id, not the captured index: the list may have been
      // refreshed or had a post removed while the request was in flight.
      final current = _posts.indexWhere((p) => p.id == post.id);
      if (current == -1) return;
      setState(
        () => _posts[current] = applyReaction(
          _posts[current],
          _confirmedReaction[post.id],
        ),
      );
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
                      builder: (_) => CommentsScreen(
                        postId: post.id,
                        onCountChanged: (count) =>
                            _updateCommentCount(post.id, count),
                      ),
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
                // Only on one's own posts, and only on the narrowed ones: it
                // is a reminder of a choice the author made, not information
                // about the post for its readers. Whoever sees the post can
                // already see it — telling them it is "for favourites only"
                // would say something about the author's list, which is
                // private.
                if (isOwnPost && post.visibility == PostVisibility.favorites)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Chip(
                      avatar: const Icon(Icons.star_outline, size: 16),
                      label: Text(l10n.visibilityFavoritesBadge),
                      labelStyle: Theme.of(context).textTheme.labelSmall,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
    final pending = takePendingAround(_items, index, _resolving);
    if (pending.isEmpty) return;
    final generation = _generation;
    final repo = ref.read(feedRepositoryProvider);
    try {
      final signed = await repo.resolveMediaUrls(pathsToSign(_items, pending));
      if (!mounted || generation != _generation) return;
      setState(() => _items = applySignedUrls(_items, pending, signed));
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
        builder: (_) => FullscreenMediaViewer(
          media: _items,
          initialIndex: index,
          resolve: ref.read(feedRepositoryProvider).resolveMediaUrls,
        ),
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
      return MediaSlide(
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
              itemBuilder: (context, index) => MediaSlide(
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
