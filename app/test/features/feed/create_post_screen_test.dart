import 'dart:typed_data';

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

  @override
  Future<void> createPost({
    required String clientToken,
    required String authorId,
    String? text,
    Uint8List? imageBytes,
    String? imageExt,
  }) async {
    tokens.add(clientToken);
    texts.add(text);
    if (createThrows) throw Exception('rejected');
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _wrap(_FakeFeedRepository repo) {
  return ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('test-user'),
      feedRepositoryProvider.overrideWithValue(repo),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CreatePostScreen(),
    ),
  );
}

Future<void> _tapPublish(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Publish'));
  await tester.pump();
}

void main() {
  testWidgets('An empty post is rejected before anything is sent', (
    tester,
  ) async {
    final repo = _FakeFeedRepository();
    await tester.pumpWidget(_wrap(repo));

    await _tapPublish(tester);

    expect(find.text('Add text or a photo'), findsOneWidget);
    expect(repo.tokens, isEmpty);
  });

  testWidgets('Whitespace alone counts as empty', (tester) async {
    final repo = _FakeFeedRepository();
    await tester.pumpWidget(_wrap(repo));

    await tester.enterText(find.byType(TextField), '   ');
    await _tapPublish(tester);

    expect(find.text('Add text or a photo'), findsOneWidget);
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
}
