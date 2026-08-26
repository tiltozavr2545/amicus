import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/feed/create_post_screen.dart';
import 'package:amicus/features/feed/feed_repository.dart';
import 'package:amicus/features/rooms/rooms_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';

/// Only the member CreatePostScreen calls needs real behaviour; the rest
/// satisfy the `implements` contract.
class _FakeFeedRepository implements FeedRepository {
  /// Every idempotency token the screen has sent, failed attempts included —
  /// the token exists for what happens across a *failed* submit, so it is
  /// recorded before [createThrows] gets its say.
  final List<String> tokens = [];

  /// Destinations each publish was sent with — the composer's checkboxes are
  /// only meaningful if what they tick actually reaches the repository.
  final List<List<String>> roomIdsSent = [];
  final List<bool> generalFeedFlags = [];
  final List<String?> texts = [];

  /// Stands in for the server (or the network) refusing the submission.
  bool createThrows = false;

  /// Recorded calls to [updatePost], for the edit-mode tests.
  int updateCalls = 0;
  String? lastUpdatedText;
  List<ComposerMediaItem>? lastFinalMedia;

  /// Stands in for the editor opening with no connectivity: the composer
  /// resolves every existing item's preview up front, and that call is fired
  /// unawaited from initState, so its failure has nowhere to propagate.
  bool resolveThrows = false;

  @override
  Future<Map<String, String>> resolveMediaUrls(
    List<String> storagePaths,
  ) async {
    if (resolveThrows) throw Exception('offline');
    return {for (final path in storagePaths) path: 'https://signed/$path'};
  }

  @override
  Future<void> createPost({
    required String clientToken,
    required String authorId,
    String? text,
    List<PendingMedia> media = const [],
    List<String> roomIds = const [],
    bool inGeneralFeed = true,
  }) async {
    tokens.add(clientToken);
    texts.add(text);
    roomIdsSent.add(roomIds);
    generalFeedFlags.add(inGeneralFeed);
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

Widget _wrap(
  _FakeFeedRepository repo, {
  Post? existingPost,
  String? initialRoomId,
  List<Room> rooms = const [],
}) {
  return ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('test-user'),
      feedRepositoryProvider.overrideWithValue(repo),
      // Empty by default, which is the composer as it was before rooms
      // existed: no destination section at all.
      myRoomsProvider.overrideWith((ref) => rooms),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CreatePostScreen(
        existingPost: existingPost,
        initialRoomId: initialRoomId,
      ),
    ),
  );
}

Room _room({required String id, required String name}) => Room(
  id: id,
  name: name,
  isDirect: false,
  ownerId: 'test-user',
  createdAt: DateTime.utc(2026, 8, 26),
  members: const [
    RoomMember(userId: 'test-user', name: 'Me'),
    RoomMember(userId: 'friend', name: 'Аня'),
  ],
);

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

    testWidgets('editing the text after a failure keeps the same token', (
      tester,
    ) async {
      final repo = _FakeFeedRepository()..createThrows = true;
      await tester.pumpWidget(_wrap(repo));

      await tester.enterText(find.byType(TextField), 'my post');
      await _tapPublish(tester);

      repo.createThrows = false;
      await tester.enterText(find.byType(TextField), 'my corrected post');
      await _tapPublish(tester);

      // The token used to be re-minted here, because the server answered a
      // repeat token by doing nothing and would have published the original
      // wording. It answers one now by rewriting the post it already has
      // (migration 20260824100000), so the correction lands *and* the first
      // attempt — which may well have committed after the screen gave up on
      // it — can no longer become a second post with a second push.
      expect(repo.tokens, hasLength(2));
      expect(repo.tokens[0], repo.tokens[1]);
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

    testWidgets(
      'an editor opened offline reports it instead of throwing, and still '
      'keeps the photo on save',
      (tester) async {
        // Regression guard: _resolveExistingMediaUrls() is started unawaited
        // from initState, so before it caught anything a failed resolve
        // escaped as an unhandled async error rather than reaching the user.
        final repo = _FakeFeedRepository()..resolveThrows = true;
        // No `url`, so the composer actually has something to resolve.
        const media = PostMedia(
          id: 'm1',
          position: 0,
          mediaType: MediaType.image,
          storagePath: 'posts/test-user/post-token/m1.jpg',
        );
        await tester.pumpWidget(
          _wrap(repo, existingPost: existingPost(media: [media])),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(
          find.text('Failed to load photos. Please try again.'),
          findsOneWidget,
        );

        // An unresolved preview is a grey tile, not a dropped photo: the slot
        // still carries its PostMedia and saving sends it on unchanged.
        await _tapSave(tester);
        expect(repo.lastFinalMedia, hasLength(1));
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

  group('destinations', () {
    testWidgets('a ticked room travels with the publish call', (tester) async {
      final repo = _FakeFeedRepository();
      await tester.pumpWidget(
        _wrap(
          repo,
          rooms: [_room(id: 'room-1', name: 'Room A')],
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.text('Room A'));
      await tester.pump();
      await _tapPublish(tester);

      expect(repo.roomIdsSent.single, ['room-1']);
      // Still the main feed as well: ticking a room adds a destination, it
      // does not move the post out of the feed.
      expect(repo.generalFeedFlags.single, isTrue);
    });

    testWidgets('composing from a room posts to that room only', (
      tester,
    ) async {
      final repo = _FakeFeedRepository();
      await tester.pumpWidget(
        _wrap(
          repo,
          initialRoomId: 'room-1',
          rooms: [_room(id: 'room-1', name: 'Room A')],
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'hello');
      await _tapPublish(tester);

      expect(repo.roomIdsSent.single, ['room-1']);
      expect(repo.generalFeedFlags.single, isFalse);
    });

    testWidgets('a post with every destination unticked is not sent', (
      tester,
    ) async {
      final repo = _FakeFeedRepository();
      await tester.pumpWidget(
        _wrap(
          repo,
          initialRoomId: 'room-1',
          rooms: [_room(id: 'room-1', name: 'Room A')],
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.text('Room A'));
      await tester.pump();
      await _tapPublish(tester);

      expect(
        find.text('Pick at least one place to publish to.'),
        findsOneWidget,
      );
      expect(repo.tokens, isEmpty);
    });
  });
}
