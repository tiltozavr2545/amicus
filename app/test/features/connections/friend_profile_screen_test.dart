import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/connections/friend_profile_screen.dart';
import 'package:amicus/features/feed/feed_repository.dart';
import 'package:amicus/features/profile/profile_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';

class _FakeProfileRepository implements ProfileRepository {
  List<ProfilePhoto> photos = const [];
  bool photosThrow = false;

  @override
  Future<List<ProfilePhoto>> fetchPhotos(String userId) async {
    if (photosThrow) throw Exception('offline');
    return photos;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The screen embeds PostListView for the friend's posts; an empty page keeps
/// it out of the way.
class _FakeFeedRepository implements FeedRepository {
  @override
  Future<List<Post>> fetchPage({
    Post? cursor,
    String? authorId,
    String? roomId,
  }) async => const [];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _wrap(_FakeProfileRepository repo) => ProviderScope(
  overrides: [
    currentUserIdProvider.overrideWithValue('me'),
    profileRepositoryProvider.overrideWithValue(repo),
    feedRepositoryProvider.overrideWithValue(_FakeFeedRepository()),
  ],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: FriendProfileScreen(friendId: 'friend-1', friendName: 'Маша'),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows the friend name it was handed, without refetching it', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_FakeProfileRepository()));
    await tester.pumpAndSettle();

    expect(find.text('Маша'), findsWidgets);
  });

  // Without this the failure is silent in a particular way: a friend whose
  // gallery failed to load looks exactly like a friend who has no photos —
  // the avatar simply does not open when tapped, with no explanation.
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

  testWidgets('a friend with no photos is not reported as a failure', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_FakeProfileRepository()));
    await tester.pumpAndSettle();

    expect(find.text('Failed to load photos. Please try again.'), findsNothing);
  });
}
