import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/feed/feed_repository.dart';
import 'package:amicus/features/feed/post_list_view.dart';
import 'package:amicus/l10n/app_localizations.dart';

/// Only [fetchPage] and [resolveMediaUrls] need real behaviour; the rest
/// satisfy the `implements` contract via `noSuchMethod`, same trick as the
/// other feed screen tests.
class _FakeFeedRepository implements FeedRepository {
  bool throwOnFetch = false;
  List<Post> pageToReturn = const [];

  /// Every path a carousel asked to have signed, in call order — what the
  /// prefetch tests assert on.
  final signedPaths = <String>[];

  /// Ids handed to [deletePost], and the comments one post has — both only
  /// for the two tests about what happens to the *rest* of the app when a
  /// post is deleted or commented on.
  final deletedPostIds = <String>[];
  List<Comment> commentsToReturn = const [];

  @override
  Future<List<Post>> fetchPage({Post? cursor, String? authorId}) async {
    if (throwOnFetch) throw Exception('offline');
    return pageToReturn;
  }

  @override
  Future<void> deletePost({
    required String postId,
    List<String> mediaStoragePaths = const [],
  }) async {
    deletedPostIds.add(postId);
    // Как сервер: следующая страница этот пост уже не отдаёт. Без этого
    // перезагрузка по тику вернула бы его обратно, и тест не отличил бы
    // «список перечитан» от «список не тронут».
    pageToReturn = [
      for (final post in pageToReturn)
        if (post.id != postId) post,
    ];
  }

  @override
  Future<CommentPage> fetchComments(String postId) async =>
      CommentPage(comments: commentsToReturn, isTruncated: false);

  /// Reaction requests in call order, each held open until the test decides
  /// its fate — which is the whole point: the bug being guarded against only
  /// exists while two of them are in flight at once.
  final reactionCalls = <Completer<void>>[];

  Future<void> _pendingReaction() {
    final completer = Completer<void>();
    reactionCalls.add(completer);
    return completer.future;
  }

  @override
  Future<void> setReaction({
    required String postId,
    required String userId,
    required ReactionType type,
  }) => _pendingReaction();

  @override
  Future<void> removeReaction({
    required String postId,
    required String userId,
  }) => _pendingReaction();

  @override
  Future<Map<String, String>> resolveMediaUrls(
    List<String> storagePaths,
  ) async {
    signedPaths.addAll(storagePaths);
    return {
      for (final path in storagePaths) path: 'https://example.invalid/$path',
    };
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A post's slides, only the first of which arrives already signed — exactly
/// what [FeedRepository.fetchPage] hands the carousel.
List<PostMedia> _images(int count) => [
  for (var i = 0; i < count; i++)
    PostMedia(
      id: 'm$i',
      position: i,
      mediaType: MediaType.image,
      storagePath: 'posts/author-1/token/m$i.jpg',
      url: i == 0 ? 'https://example.invalid/signed?m=0' : null,
    ),
];

Post _post(
  String id, {
  List<PostMedia> media = const [],
  String authorId = 'author-1',
  PostVisibility visibility = PostVisibility.connections,
}) => Post(
  id: id,
  authorId: authorId,
  authorName: 'Alice',
  createdAt: DateTime(2026, 1, 1, 12),
  clientToken: 'token-of-$id',
  visibility: visibility,
  text: 'text of $id',
  media: media,
);

/// [container], when given, lets a test poke providers from the outside —
/// bumping [feedRefreshTickProvider] the way muting or saving an edit does.
Widget _wrap(_FakeFeedRepository repo, {ProviderContainer? container}) {
  const app = MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: PostListView()),
  );
  if (container != null) {
    return UncontrolledProviderScope(container: container, child: app);
  }
  return ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('test-user'),
      feedRepositoryProvider.overrideWithValue(repo),
    ],
    child: app,
  );
}

ProviderContainer _container(_FakeFeedRepository repo) => ProviderContainer(
  overrides: [
    currentUserIdProvider.overrideWithValue('test-user'),
    feedRepositoryProvider.overrideWithValue(repo),
  ],
);

/// The cache slot the widget under test writes to: scoped to the viewer as
/// well as the feed scope, so one account can't be served another's page.
const _cacheKey = 'feed_cache_test-user_main';

const _failedToLoad = 'Failed to load feed. Please try again.';

const _likeTooltip = 'Like';
const _dislikeTooltip = 'Dislike';

/// Pumps a fresh list holding one reaction-less post, then leaves 👍 and 👎
/// both in flight — the state every test below starts from.
Future<_FakeFeedRepository> _twoReactionsInFlight(WidgetTester tester) async {
  final repo = _FakeFeedRepository()..pageToReturn = [_post('p1')];
  await tester.pumpWidget(_wrap(repo));
  await tester.pump();
  await tester.pump();

  await tester.tap(find.byTooltip(_likeTooltip));
  await tester.pump();
  await tester.tap(find.byTooltip(_dislikeTooltip));
  await tester.pump();

  expect(repo.reactionCalls, hasLength(2));
  return repo;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('a reaction that fails while another is in flight', () {
    // `.timeout()` stops waiting without cancelling, so "the request failed"
    // and "the request landed" are routinely indistinguishable from here —
    // which makes two reactions in flight at once an ordinary Tuesday rather
    // than a stress test.

    testWidgets('does not undo a newer one that already succeeded', (
      tester,
    ) async {
      final repo = await _twoReactionsInFlight(tester);

      // The 👎 lands...
      repo.reactionCalls[1].complete();
      await tester.pump();
      // ...and only then does the 👍 give up.
      repo.reactionCalls[0].completeError(Exception('timeout'));
      await tester.pump();

      // The old code restored the Post captured before the 👍 — no reaction at
      // all — over a dislike the server was holding and the user could see.
      expect(find.byIcon(Icons.thumb_down), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('lands back on the server state when both fail', (
      tester,
    ) async {
      final repo = await _twoReactionsInFlight(tester);

      repo.reactionCalls[0].completeError(Exception('timeout'));
      await tester.pump();
      repo.reactionCalls[1].completeError(Exception('timeout'));
      await tester.pump();

      // Nothing was ever confirmed, so the card has to end where it started —
      // not on the state between the two taps, which is what rolling back to
      // "whatever this request saw" would give.
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      expect(find.byIcon(Icons.thumb_down_outlined), findsOneWidget);
      expect(find.text('1'), findsNothing);
    });
  });

  testWidgets(
    'shows the blocking error when there is no cache and the fetch fails',
    (tester) async {
      final repo = _FakeFeedRepository()..throwOnFetch = true;
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text(_failedToLoad), findsOneWidget);
    },
  );

  testWidgets(
    'falls back to the last-seen posts instead of going blank when offline',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        _cacheKey: jsonEncode([_post('cached-1').toCacheJson()]),
      });
      final repo = _FakeFeedRepository()..throwOnFetch = true;
      await tester.pumpWidget(_wrap(repo));
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      // Lets the snackbar's entrance animation finish, well short of its
      // multi-second auto-dismiss.
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('text of cached-1'), findsOneWidget);
      // The failed refresh is still reported, just as a snackbar rather than
      // by hiding what's already on screen.
      expect(find.text(_failedToLoad), findsOneWidget);
    },
  );

  testWidgets('a successful fetch replaces the cached preview outright', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      _cacheKey: jsonEncode([_post('stale').toCacheJson()]),
    });
    final repo = _FakeFeedRepository()..pageToReturn = [_post('fresh')];
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('text of fresh'), findsOneWidget);
    expect(find.text('text of stale'), findsNothing);
  });

  testWidgets(
    "a post's photo is cached under its storage path, not the signed URL",
    (tester) async {
      final repo = _FakeFeedRepository()
        ..pageToReturn = [
          _post(
            'p1',
            media: const [
              PostMedia(
                id: 'm1',
                position: 0,
                mediaType: MediaType.image,
                storagePath: 'posts/author-1/token/m1.jpg',
                url: 'https://example.invalid/signed?token=abc',
              ),
            ],
          ),
        ];
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      // Two signed URLs for the same photo, minted on two different app
      // launches, must resolve to the same on-disk cache entry — otherwise
      // every restart re-downloads a photo it has already seen.
      expect(image.cacheKey, 'posts/author-1/token/m1.jpg');
      expect(image.imageUrl, 'https://example.invalid/signed?token=abc');
    },
  );

  testWidgets(
    'a post with several media items shows a position counter, no dots',
    (tester) async {
      final repo = _FakeFeedRepository()
        ..pageToReturn = [_post('p1', media: _images(3))];
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('1/3'), findsOneWidget);
    },
  );

  // The whole point of the prefetch: the next slide is signed while the
  // viewer is still looking at the current one, so swiping doesn't start a
  // round trip the viewer has to wait out.
  testWidgets('the slide next to the shown one is signed before it is swiped '
      'to, the rest are not', (tester) async {
    final repo = _FakeFeedRepository()
      ..pageToReturn = [_post('p1', media: _images(4))];
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(repo.signedPaths, ['posts/author-1/token/m1.jpg']);
    // ...and its image widget is already in the tree — off screen in the
    // PageView's own cache region (hence `skipOffstage: false`), which is
    // what gets the bytes downloading before the swipe rather than after it.
    final urls = tester
        .widgetList<CachedNetworkImage>(
          find.byType(CachedNetworkImage, skipOffstage: false),
        )
        .map((w) => w.imageUrl);
    expect(
      urls,
      contains('https://example.invalid/posts/author-1/token/m1.jpg'),
    );
  });

  // The bug this fixes: a post scrolled out of the list has its carousel
  // disposed, and the rebuilt one used to start over at photo 1 — so
  // scrolling down and back lost where you were in every post you passed.
  testWidgets('a carousel comes back on the slide it was left on', (
    tester,
  ) async {
    final repo = _FakeFeedRepository()
      ..pageToReturn = [
        for (final id in ['p1', 'p2', 'p3']) _post(id, media: _images(3)),
      ];
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.drag(find.byType(PageView).first, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);

    // Far enough past the first card (taller than the viewport on its own)
    // to leave the list's cache region behind, so its carousel is really
    // gone rather than merely off screen.
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 2000));
    await tester.pumpAndSettle();

    expect(find.text('2/3'), findsOneWidget);
  });

  // The cache is keyed by post, not by slot in the list: the post that moved
  // to index 0 must not inherit where the viewer left the post previously
  // shown there.
  testWidgets('a remembered position follows its post, not its position in '
      'the feed', (tester) async {
    final repo = _FakeFeedRepository()
      ..pageToReturn = [_post('p1', media: _images(3))];
    final container = _container(repo);
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(repo, container: container));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);

    // A newer post arrives on top, so index 0's State is reused for it.
    repo.pageToReturn = [
      _post('p2', media: _images(3)),
      _post('p1', media: _images(3)),
    ];
    container.read(feedRefreshTickProvider.notifier).bump();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // The new post starts at its own first slide rather than inheriting the
    // slide the post previously drawn by this State was left on.
    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('2/3'), findsNothing);
  });

  // Regression: _MediaCarousel owns its own copy of the media list so it can
  // fill in lazily-resolved URLs. Without a didUpdateWidget, the State reused
  // for whatever post now sits at this index kept painting the previous
  // post's photos — under the new post's author and timestamp.
  testWidgets('a refresh that reshuffles the feed repaints each carousel', (
    tester,
  ) async {
    PostMedia mediaOf(String post) => PostMedia(
      id: 'm-of-$post',
      position: 0,
      mediaType: MediaType.image,
      storagePath: 'posts/author-1/token/$post.jpg',
      url: 'https://example.invalid/signed?p=$post',
    );

    final repo = _FakeFeedRepository()
      ..pageToReturn = [
        _post('old', media: [mediaOf('old')]),
      ];
    final container = _container(repo);
    addTearDown(container.dispose);

    await tester.pumpWidget(_wrap(repo, container: container));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .imageUrl,
      'https://example.invalid/signed?p=old',
    );

    // A new post arrives at the top, so index 0's State is reused for it.
    repo.pageToReturn = [
      _post('new', media: [mediaOf('new')]),
      _post('old', media: [mediaOf('old')]),
    ];
    container.read(feedRefreshTickProvider.notifier).bump();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final urls = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .map((w) => w.imageUrl)
        .toList();
    expect(urls.first, 'https://example.invalid/signed?p=new');
    expect(urls, hasLength(2));
  });

  // Лента и профиль — два живых PostListView в IndexedStack'е shell'а.
  // Удаление убирало пост только из своего списка, и во втором он оставался
  // кликабельной карточкой: реакцию по нему отбивает RLS (и [_react] эту
  // ошибку молча откатывает), комментарии открываются пустыми. Правка поста,
  // mute/block и новый пост через этот тик уже проходили — удаление было
  // единственной мутацией ленты, которая его не дёргала.
  testWidgets('deleting a post bumps the tick the other lists listen on', (
    tester,
  ) async {
    final repo = _FakeFeedRepository()
      ..pageToReturn = [
        Post(
          id: 'p1',
          // Меню «⋮» рисуется только на своём посте.
          authorId: 'test-user',
          authorName: 'Me',
          createdAt: DateTime(2026, 1, 1, 12),
          text: 'mine',
        ),
      ];
    final container = _container(repo);
    addTearDown(container.dispose);
    await tester.pumpWidget(_wrap(repo, container: container));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final before = container.read(feedRefreshTickProvider);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    // Подтверждение — вторая «Delete», уже в диалоге.
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(repo.deletedPostIds, ['p1']);
    expect(find.text('mine'), findsNothing);
    expect(container.read(feedRefreshTickProvider), greaterThan(before));
  });

  // Экран комментариев открывался без `.then`, ничего не возвращал и тик не
  // дёргал, поэтому число на карточке не менялось никогда: написал коммент,
  // вернулся — прежняя цифра, до первого pull-to-refresh.
  testWidgets('the comment count on the card follows what the thread loaded', (
    tester,
  ) async {
    final repo = _FakeFeedRepository()
      // Стартовое число заведомо не совпадает ни с одним счётчиком реакций
      // (те по нулям), чтобы обе проверки ниже били в нужный Text.
      ..pageToReturn = [_post('p1').copyWith(commentCount: 5)]
      ..commentsToReturn = [
        for (var i = 0; i < 2; i++)
          Comment(
            id: 'c$i',
            authorId: 'author-1',
            authorName: 'Alice',
            text: 'comment $i',
            createdAt: DateTime(2026, 1, 1, 13),
          ),
        // Заглушка удалённого комментария: `comment_summary()` считает
        // `deleted_at is null`, так что в число она не попадает.
        Comment(
          id: 'c-gone',
          authorId: 'author-1',
          authorName: 'Alice',
          text: '',
          createdAt: DateTime(2026, 1, 1, 14),
          isDeleted: true,
        ),
      ];
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('5'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.mode_comment_outlined));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
    await tester.pumpAndSettle();

    expect(find.text('2'), findsOneWidget);
    expect(find.text('5'), findsNothing);
  });

  testWidgets('a single-media post shows no position counter', (tester) async {
    final repo = _FakeFeedRepository()
      ..pageToReturn = [
        _post(
          'p1',
          media: const [
            PostMedia(
              id: 'm1',
              position: 0,
              mediaType: MediaType.image,
              storagePath: 'posts/author-1/token/m1.jpg',
              url: 'https://example.invalid/signed?m=0',
            ),
          ],
        ),
      ];
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('1/1'), findsNothing);
  });

  group('visibility badge', () {
    testWidgets('own favourites-only post is marked as one', (tester) async {
      final repo = _FakeFeedRepository()
        ..pageToReturn = [
          _post(
            'p1',
            authorId: 'test-user',
            visibility: PostVisibility.favorites,
          ),
        ];
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      expect(find.text('Favourites only'), findsOneWidget);
    });

    testWidgets('somebody else\'s post never carries the mark', (tester) async {
      // Whoever sees the post can already see it; saying "favourites only"
      // would tell them something about the author's private list.
      final repo = _FakeFeedRepository()
        ..pageToReturn = [_post('p1', visibility: PostVisibility.favorites)];
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      expect(find.text('Favourites only'), findsNothing);
    });

    testWidgets('an ordinary own post carries no mark either', (tester) async {
      final repo = _FakeFeedRepository()
        ..pageToReturn = [_post('p1', authorId: 'test-user')];
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      expect(find.text('Favourites only'), findsNothing);
    });
  });
}
