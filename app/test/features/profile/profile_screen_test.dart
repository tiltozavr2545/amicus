import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/feed/feed_repository.dart';
import 'package:amicus/features/profile/profile_repository.dart';
import 'package:amicus/features/profile/profile_screen.dart';
import 'package:amicus/l10n/app_localizations.dart';

/// Only what ProfileScreen actually calls; the rest satisfies `implements`
/// through noSuchMethod, the same trick the other screen tests use.
class _FakeProfileRepository implements ProfileRepository {
  String name = 'Тимофей';
  List<ProfilePhoto> photos = const [];
  bool photosThrow = false;
  String? savedName;

  /// What `updateName` answers with when it doesn't succeed. `Exception?`, not
  /// `Object?`: only what actually comes from the server goes in here.
  Exception? updateNameError;

  @override
  Future<Profile> fetchProfile(String userId) async =>
      Profile(id: userId, name: name);

  /// How many times the gallery was re-read — the test about returning from
  /// the delete screen relies on this.
  int fetchPhotosCalls = 0;

  @override
  Future<List<ProfilePhoto>> fetchPhotos(String userId) async {
    fetchPhotosCalls++;
    if (photosThrow) throw Exception('offline');
    return photos;
  }

  @override
  Future<void> updateName({
    required String userId,
    required String name,
  }) async {
    if (updateNameError != null) throw updateNameError!;
    savedName = name;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// ProfileScreen embeds PostListView for "my posts"; an empty page keeps it
/// out of the way of what these tests are about.
class _FakeFeedRepository implements FeedRepository {
  @override
  Future<List<Post>> fetchPage({
    Post? cursor,
    String? authorId,
    Set<String> mutedAuthorIds = const {},
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _wrap(_FakeProfileRepository repo) => ProviderScope(
  overrides: [
    currentUserIdProvider.overrideWithValue('user-1'),
    profileRepositoryProvider.overrideWithValue(repo),
    feedRepositoryProvider.overrideWithValue(_FakeFeedRepository()),
  ],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ProfileScreen(),
  ),
);

Finder get _nameField => find.byType(TextField).first;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the name field is seeded from the loaded profile', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_FakeProfileRepository()));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(_nameField).controller!.text, 'Тимофей');
  });

  // The regression this file was written for. The seed used to be guarded by
  // "is the field empty", and a listener rebuilds the screen on every
  // keystroke — so clearing the field immediately put the old name back,
  // caret and all, and a name could only ever be edited around its existing
  // text rather than replaced.
  testWidgets('clearing the name field leaves it cleared', (tester) async {
    await tester.pumpWidget(_wrap(_FakeProfileRepository()));
    await tester.pumpAndSettle();

    await tester.enterText(_nameField, '');
    await tester.pump();

    expect(tester.widget<TextField>(_nameField).controller!.text, '');
  });

  testWidgets('a cleared field can be retyped from scratch', (tester) async {
    final repo = _FakeProfileRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(_nameField, '');
    await tester.pump();
    await tester.enterText(_nameField, 'Тим');
    await tester.pump();

    expect(tester.widget<TextField>(_nameField).controller!.text, 'Тим');
  });

  testWidgets('a later rebuild does not re-seed over what was typed', (
    tester,
  ) async {
    // Seeding is once per screen, not once per build: the profile provider
    // resolving again (a save, an invalidate) must not clobber an edit in
    // progress.
    final repo = _FakeProfileRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(_nameField, 'Другое имя');
    await tester.pump();
    // Force extra rebuilds of the data branch.
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(_nameField).controller!.text, 'Другое имя');
  });

  testWidgets('Save appears only once the name differs from the profile', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_FakeProfileRepository()));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);

    await tester.enterText(_nameField, 'Тимофей Русаков');
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
  });

  // The failure that used to be invisible: `failedToLoadPhotosError` existed
  // in both locales and was wired to nothing, so a gallery that failed to load
  // was indistinguishable from a profile with no photos — the buttons sat
  // disabled and the avatar showed the placeholder, with no explanation.
  testWidgets('a failed photo load says so instead of looking empty', (
    tester,
  ) async {
    final repo = _FakeProfileRepository()..photosThrow = true;
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(
      find.text('Failed to load photos. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets('a gallery that loads empty says nothing about failure', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_FakeProfileRepository()));
    await tester.pumpAndSettle();

    expect(find.text('Failed to load photos. Please try again.'), findsNothing);
  });

  // The gallery is re-read on ANY return from the delete screen, not only
  // when it returned `true`. It returns `true` only on full success, and
  // `.timeout()` stops waiting without cancelling the request: the rows in
  // `profile_photos` may already be gone (deleteRowsThenObjects deletes them
  // first), the screen showed an error and stayed open, and we come back here
  // with `null`. With the old `if (changed == true)` the profile's list kept
  // rows that no longer existed, and `reorder_profile_photos()` then answered
  // PT422 forever — the profile screen lives as a shell branch and doesn't
  // re-read itself.
  testWidgets('backing out of the delete screen still re-reads the gallery', (
    tester,
  ) async {
    final repo = _FakeProfileRepository()
      ..photos = const [
        ProfilePhoto(id: 'ph1', storagePath: 'avatars/user-1/a.jpg'),
      ];
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    final before = repo.fetchPhotosCalls;

    await tester.tap(find.text('Delete photo'));
    await tester.pumpAndSettle();
    // Leave without a single mutation — the route returns `null`.
    Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
    await tester.pumpAndSettle();

    expect(repo.fetchPhotosCalls, greaterThan(before));
  });

  // Before 20260924100000 the write ban was enforced only by BEFORE INSERT,
  // and a rename under a ban went through — so AMB01 was unreachable from
  // here, and the screen didn't handle it. The migration added `before update
  // of name on users`, and with it came the chance to show a banned user
  // "try again" — an invitation to retry something that won't work until the
  // ban expires.
  testWidgets('a write ban on rename names the date instead of "try again"', (
    tester,
  ) async {
    final repo = _FakeProfileRepository()
      ..updateNameError = const PostgrestException(
        message: 'Writing is restricted for this account',
        code: 'AMB01',
        details: '2026-10-01T09:00:00Z',
      );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(_nameField, 'Новое имя');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // The date comes from DETAIL, not made up, so that's exactly what's
    // checked.
    expect(
      find.textContaining('the restriction lasts until Oct 1, 2026'),
      findsOneWidget,
    );
    expect(find.textContaining('Please try again'), findsNothing);
    expect(repo.savedName, isNull);
  });

  // The other half of the same branch: an ordinary failure must stay
  // ordinary. Without it, the "showed the date" check would also pass on code
  // that always talks about a ban.
  testWidgets('an ordinary failure to save the name still says "try again"', (
    tester,
  ) async {
    final repo = _FakeProfileRepository()
      ..updateNameError = Exception('offline');
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(_nameField, 'Новое имя');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('the restriction lasts until'), findsNothing);
    expect(find.textContaining('Failed to save name'), findsOneWidget);
  });
}
