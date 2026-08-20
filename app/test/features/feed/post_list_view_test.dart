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

  @override
  Future<List<Post>> fetchPage({Post? cursor, String? authorId}) async {
    if (throwOnFetch) throw Exception('offline');
    return pageToReturn;
  }

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

Post _post(String id, {List<PostMedia> media = const []}) => Post(
  id: id,
  authorId: 'author-1',
  authorName: 'Alice',
  createdAt: DateTime(2026, 1, 1, 12),
  clientToken: 'token-of-$id',
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
}
