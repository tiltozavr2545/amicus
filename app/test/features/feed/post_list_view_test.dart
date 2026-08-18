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

/// Only [fetchPage] needs real behaviour; the rest satisfy the `implements`
/// contract via `noSuchMethod`, same trick as the other feed screen tests.
class _FakeFeedRepository implements FeedRepository {
  bool throwOnFetch = false;
  List<Post> pageToReturn = const [];

  @override
  Future<List<Post>> fetchPage({Post? cursor, String? authorId}) async {
    if (throwOnFetch) throw Exception('offline');
    return pageToReturn;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Post _post(String id, {String? imagePath, String? imageUrl}) => Post(
  id: id,
  authorId: 'author-1',
  authorName: 'Alice',
  createdAt: DateTime(2026, 1, 1, 12),
  text: 'text of $id',
  imagePath: imagePath,
  imageUrl: imageUrl,
);

Widget _wrap(_FakeFeedRepository repo) {
  return ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('test-user'),
      feedRepositoryProvider.overrideWithValue(repo),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: PostListView()),
    ),
  );
}

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
        'feed_cache_main': jsonEncode([_post('cached-1').toCacheJson()]),
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
      'feed_cache_main': jsonEncode([_post('stale').toCacheJson()]),
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
            imagePath: 'posts/author-1/token.jpg',
            imageUrl: 'https://example.invalid/signed?token=abc',
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
      expect(image.cacheKey, 'posts/author-1/token.jpg');
      expect(image.imageUrl, 'https://example.invalid/signed?token=abc');
    },
  );
}
