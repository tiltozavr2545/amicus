import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  @override
  Future<Profile> fetchProfile(String userId) async =>
      Profile(id: userId, name: name);

  @override
  Future<List<ProfilePhoto>> fetchPhotos(String userId) async {
    if (photosThrow) throw Exception('offline');
    return photos;
  }

  @override
  Future<void> updateName({
    required String userId,
    required String name,
  }) async {
    savedName = name;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// ProfileScreen embeds PostListView for "my posts"; an empty page keeps it
/// out of the way of what these tests are about.
class _FakeFeedRepository implements FeedRepository {
  @override
  Future<List<Post>> fetchPage({Post? cursor, String? authorId}) async =>
      const [];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
}
