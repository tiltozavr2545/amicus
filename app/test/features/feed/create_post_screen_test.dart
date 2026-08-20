import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/feed/create_post_screen.dart';
import 'package:amicus/features/feed/feed_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';

/// Only the member CreatePostScreen calls needs real behaviour; the rest
/// satisfy the `implements` contract.
class _FakeFeedRepository implements FeedRepository {
  /// Every idempotency token the screen has sent, failed attempts included —
  /// the token exists for what happens across a *failed* submit, so it is
  /// recorded before [createThrows] gets its say.
  final List<String> tokens = [];
  final List<String?> texts = [];

  /// Stands in for the server (or the network) refusing the submission.
  bool createThrows = false;

  /// Recorded calls to [updatePost], for the edit-mode tests.
  int updateCalls = 0;
  String? lastUpdatedText;
  List<ComposerMediaItem>? lastFinalMedia;

  @override
  Future<void> createPost({
    required String clientToken,
    required String authorId,
    String? text,
    List<PendingMedia> media = const [],
  }) async {
    tokens.add(clientToken);
    texts.add(text);
    if (createThrows) throw Exception('rejected');
  }

  @override
  Future<void> updatePost({
    required String postId,
    required String authorId,
    required String postClientToken,
    String? text,
    required List<ComposerMediaItem> finalMedia,
  }) async {
    updateCalls++;
    lastUpdatedText = text;
    lastFinalMedia = finalMedia;
    if (createThrows) throw Exception('rejected');
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _wrap(_FakeFeedRepository repo, {Post? existingPost}) {
  return ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('test-user'),
      feedRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CreatePostScreen(existingPost: existingPost),
    ),
  );
}

Future<void> _tapPublish(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Publish'));
  await tester.pump();
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Save'));
  await tester.pump();
}

void main() {
  testWidgets('An empty post is rejected before anything is sent', (
    tester,
  ) async {
    final repo = _FakeFeedRepository();
    await tester.pumpWidget(_wrap(repo));

    await _tapPublish(tester);

    expect(find.text('Add text, a photo, or a video'), findsOneWidget);
    expect(repo.tokens, isEmpty);
  });

  testWidgets('Whitespace alone counts as empty', (tester) async {
    final repo = _FakeFeedRepository();
    await tester.pumpWidget(_wrap(repo));

    await tester.enterText(find.byType(TextField), '   ');
    await _tapPublish(tester);

    expect(find.text('Add text, a photo, or a video'), findsOneWidget);
    expect(repo.tokens, isEmpty);
  });

  testWidgets('A failed publish shows a message and keeps the typed text', (
    tester,
  ) async {
    final repo = _FakeFeedRepository()..createThrows = true;
    await tester.pumpWidget(_wrap(repo));

    await tester.enterText(find.byType(TextField), 'my post');
    await _tapPublish(tester);

    expect(find.text('Failed to publish. Please try again.'), findsOneWidget);
    // The text survives so the user can retry without retyping it — which is
    // exactly what makes the token below matter.
    expect(find.widgetWithText(TextField, 'my post'), findsOneWidget);
  });

  // `.timeout()` only stops waiting; it does not cancel the request. So a
  // publish that "failed" may in fact have committed, and the retry the test
  // above invites has to be recognisable as the *same* submission, or the user
  // ends up with the post twice.
  group('idempotency token', () {
    testWidgets('a retry of unchanged content reuses the token', (
      tester,
    ) async {
      final repo = _FakeFeedRepository()..createThrows = true;
      await tester.pumpWidget(_wrap(repo));

      await tester.enterText(find.byType(TextField), 'my post');
      await _tapPublish(tester);

      repo.createThrows = false;
      await _tapPublish(tester);

      expect(repo.tokens, hasLength(2));
      expect(repo.tokens[0], repo.tokens[1]);
    });

    testWidgets('editing the text after a failure mints a new token', (
      tester,
    ) async {
      final repo = _FakeFeedRepository()..createThrows = true;
      await tester.pumpWidget(_wrap(repo));

      await tester.enterText(find.byType(TextField), 'my post');
      await _tapPublish(tester);

      // Reusing the token here would let the server answer the correction with
      // "already have that one" and silently publish the original wording.
      repo.createThrows = false;
      await tester.enterText(find.byType(TextField), 'my corrected post');
      await _tapPublish(tester);

      expect(repo.tokens, hasLength(2));
      expect(repo.tokens[0], isNot(repo.tokens[1]));
      expect(repo.texts.last, 'my corrected post');
    });
  });

  group('edit mode', () {
    Post existingPost({List<PostMedia> media = const []}) => Post(
      id: 'post-1',
      authorId: 'test-user',
      authorName: 'Me',
      createdAt: DateTime(2026, 1, 1),
      clientToken: 'post-token',
      text: 'original text',
      media: media,
    );

    testWidgets(
      'shows the edit title and Save button, prefilled with the post',
      (tester) async {
        final repo = _FakeFeedRepository();
        await tester.pumpWidget(_wrap(repo, existingPost: existingPost()));

        expect(find.text('Edit post'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Save'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'original text'), findsOneWidget);
      },
    );

    testWidgets('saving calls updatePost, not createPost', (tester) async {
      final repo = _FakeFeedRepository();
      await tester.pumpWidget(_wrap(repo, existingPost: existingPost()));

      await tester.enterText(find.byType(TextField), 'edited text');
      await _tapSave(tester);

      expect(repo.updateCalls, 1);
      expect(repo.lastUpdatedText, 'edited text');
      expect(repo.tokens, isEmpty);
    });

    testWidgets(
      'a kept photo appears in the grid and survives to the save call',
      (tester) async {
        final repo = _FakeFeedRepository();
        final media = const PostMedia(
          id: 'm1',
          position: 0,
          mediaType: MediaType.image,
          storagePath: 'posts/test-user/post-token/m1.jpg',
          url: 'https://example.invalid/signed',
        );
        await tester.pumpWidget(
          _wrap(repo, existingPost: existingPost(media: [media])),
        );
        await tester.pump();

        await _tapSave(tester);

        expect(repo.updateCalls, 1);
        expect(repo.lastFinalMedia, hasLength(1));
        expect(repo.lastFinalMedia!.single, isA<KeptMedia>());
        expect((repo.lastFinalMedia!.single as KeptMedia).media.id, 'm1');
      },
    );

    testWidgets('a failed save shows a dedicated message', (tester) async {
      final repo = _FakeFeedRepository()..createThrows = true;
      await tester.pumpWidget(_wrap(repo, existingPost: existingPost()));

      await _tapSave(tester);

      expect(
        find.text('Failed to save changes. Please try again.'),
        findsOneWidget,
      );
    });
  });
}
