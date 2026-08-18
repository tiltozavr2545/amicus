import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/feed/comments_screen.dart';
import 'package:amicus/features/feed/feed_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';

/// Only the members CommentsScreen calls need real behaviour; the rest satisfy
/// the `implements` contract.
class _FakeFeedRepository implements FeedRepository {
  List<Comment> comments = [];
  int addCalls = 0;

  /// What the last addComment call was filed under, so a test can check the
  /// one-level nesting rule rather than just that something was sent.
  String? lastParentCommentId;
  String? lastReplyToId;

  /// Every idempotency token the screen has sent, failed attempts included —
  /// the point of the token is what happens across a *failed* send, so it is
  /// recorded before [addThrows] gets its say.
  final List<String> tokens = [];

  /// Makes [addComment] fail, standing in for the server rejecting a reply —
  /// its target was tombstoned or its author blocked while it was being typed.
  bool addThrows = false;

  @override
  Future<List<Comment>> fetchComments(String postId) async => comments;

  @override
  Future<void> addComment({
    required String clientToken,
    required String postId,
    required String authorId,
    required String text,
    String? parentCommentId,
    String? replyToId,
  }) async {
    tokens.add(clientToken);
    if (addThrows) throw Exception('rejected');
    addCalls++;
    lastParentCommentId = parentCommentId;
    lastReplyToId = replyToId;
    comments = [
      ...comments,
      Comment(
        id: 'new-$addCalls',
        authorId: authorId,
        authorName: 'Me',
        text: text,
        createdAt: DateTime(2026, 1, 2),
        parentCommentId: parentCommentId,
        replyToId: replyToId,
      ),
    ];
  }

  @override
  Future<void> deleteComment(String commentId) async {}

  @override
  Future<List<Post>> fetchPage({Post? cursor}) async => [];

  @override
  Future<void> createPost({
    required String clientToken,
    required String authorId,
    String? text,
    dynamic imageBytes,
    String? imageExt,
  }) async {}

  @override
  Future<void> deletePost({required String postId, String? imagePath}) async {}

  @override
  Future<void> setReaction({
    required String postId,
    required String userId,
    required ReactionType type,
  }) async {}

  @override
  Future<void> removeReaction({
    required String postId,
    required String userId,
  }) async {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Comment _comment(
  String id, {
  String author = 'Alice',
  String? parentCommentId,
  String? replyToId,
  int minute = 0,
}) => Comment(
  id: id,
  authorId: 'user-$author',
  authorName: author,
  text: 'text of $id',
  createdAt: DateTime(2026, 1, 1, 12, minute),
  parentCommentId: parentCommentId,
  replyToId: replyToId,
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
      home: CommentsScreen(postId: 'post-1'),
    ),
  );
}

void main() {
  // The screen's _errorMessage is drawn *in place of* the list, so it can only
  // ever be seen while the list is missing. A send that fails once comments are
  // on screen therefore has to report some other way, or it reports nowhere:
  // the spinner blinks, the composer stops, and the user retries forever.
  testWidgets('A failed send shows a snackbar and keeps the typed text', (
    tester,
  ) async {
    final repo = _FakeFeedRepository()
      ..comments = [_comment('c1')]
      ..addThrows = true;
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();
    expect(find.text('text of c1'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'my reply');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(find.text('Failed to send. Please try again.'), findsOneWidget);
    // The text survives so the user can retry without retyping it.
    expect(find.widgetWithText(TextField, 'my reply'), findsOneWidget);
  });

  // `.timeout()` only stops waiting; it does not cancel the request. So a send
  // that "failed" may in fact have committed, and the retry the test above
  // invites has to be recognisable as the *same* submission or it lands twice.
  group('idempotency token', () {
    testWidgets('a retry of unchanged content reuses the token', (
      tester,
    ) async {
      final repo = _FakeFeedRepository()
        ..comments = [_comment('c1')]
        ..addThrows = true;
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'my comment');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // The retry: same text, still sitting in the composer.
      repo.addThrows = false;
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();

      expect(repo.tokens, hasLength(2));
      expect(repo.tokens[0], repo.tokens[1]);
    });

    testWidgets('editing the text after a failure mints a new token', (
      tester,
    ) async {
      final repo = _FakeFeedRepository()
        ..comments = [_comment('c1')]
        ..addThrows = true;
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'my comment');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // Reusing the token here would let the server answer the edit with
      // "already have that one" and silently keep the original wording.
      repo.addThrows = false;
      await tester.enterText(find.byType(TextField), 'my corrected comment');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();

      expect(repo.tokens, hasLength(2));
      expect(repo.tokens[0], isNot(repo.tokens[1]));
    });

    testWidgets('changing who the reply addresses mints a new token', (
      tester,
    ) async {
      final repo = _FakeFeedRepository()
        ..comments = [_comment('c1')]
        ..addThrows = true;
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      await tester.tap(find.widgetWithText(TextButton, 'Reply'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'my comment');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // Same text, but now meant as a root comment rather than a reply.
      repo.addThrows = false;
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();

      expect(repo.tokens, hasLength(2));
      expect(repo.tokens[0], isNot(repo.tokens[1]));
      expect(repo.lastParentCommentId, null);
    });

    testWidgets('a fresh comment after a success gets its own token', (
      tester,
    ) async {
      final repo = _FakeFeedRepository()..comments = [_comment('c1')];
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'second');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();

      expect(repo.tokens, hasLength(2));
      expect(repo.tokens[0], isNot(repo.tokens[1]));
    });
  });

  testWidgets('A successful send clears the field and shows no error', (
    tester,
  ) async {
    final repo = _FakeFeedRepository()..comments = [_comment('c1')];
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'my comment');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();

    expect(repo.addCalls, 1);
    expect(find.text('my comment'), findsOneWidget); // now in the list
    expect(find.widgetWithText(TextField, 'my comment'), findsNothing);
    expect(find.text('Failed to send. Please try again.'), findsNothing);
  });

  // Nesting is capped at one level, and the client is what enforces it when
  // composing: a reply always gets filed under the *root* of the branch, never
  // under the comment it answers. The server rejects anything deeper, so
  // getting this wrong turns every reply-to-a-reply into a failed send.
  group('reply targeting', () {
    testWidgets('answering the root files under the root', (tester) async {
      final repo = _FakeFeedRepository()..comments = [_comment('c1')];
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      await tester.tap(find.widgetWithText(TextButton, 'Reply'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'answering the root');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(repo.lastParentCommentId, 'c1');
      expect(repo.lastReplyToId, 'c1');
    });

    testWidgets('answering a reply files under that reply\'s root, and '
        'addresses the reply', (tester) async {
      final repo = _FakeFeedRepository()
        ..comments = [
          _comment('c1', author: 'Alice'),
          _comment(
            'c2',
            author: 'Bob',
            parentCommentId: 'c1',
            replyToId: 'c1',
            minute: 1,
          ),
        ];
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      // Two rows, root first: the second Reply button belongs to Bob's reply.
      await tester.tap(find.widgetWithText(TextButton, 'Reply').at(1));
      await tester.pump();
      expect(find.textContaining('Bob'), findsWidgets);

      await tester.enterText(find.byType(TextField), 'answering the reply');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // Filed under the root — not under c2, which would be depth two.
      expect(repo.lastParentCommentId, 'c1');
      expect(repo.lastReplyToId, 'c2');
    });

    testWidgets('cancelling the reply banner goes back to a root comment', (
      tester,
    ) async {
      final repo = _FakeFeedRepository()..comments = [_comment('c1')];
      await tester.pumpWidget(_wrap(repo));
      await tester.pump();

      await tester.tap(find.widgetWithText(TextButton, 'Reply'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'plain comment');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(repo.lastParentCommentId, null);
      expect(repo.lastReplyToId, null);
    });
  });

  testWidgets('A failed load does show its message in place of the list', (
    tester,
  ) async {
    final repo = _FailingLoadRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    expect(
      find.text('Failed to load comments. Please try again.'),
      findsOneWidget,
    );
  });
}

class _FailingLoadRepository extends _FakeFeedRepository {
  @override
  Future<List<Comment>> fetchComments(String postId) async {
    throw Exception('offline');
  }
}
