import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/profile/profile_photos_screen.dart';
import 'package:amicus/features/profile/profile_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';

/// Records what the screens ask for. `avatarBytesProvider` is left alone: it
/// resolves to a loading state here, which is exactly the "no bytes yet" branch
/// the thumbnails already handle with a placeholder box — so these tests
/// exercise selection and ordering without needing image bytes at all.
class _FakeProfileRepository implements ProfileRepository {
  List<ProfilePhoto>? reorderedTo;
  List<ProfilePhoto>? deleted;
  bool throwOnReorder = false;
  bool throwOnDelete = false;

  @override
  Future<void> reorderPhotos({required List<ProfilePhoto> order}) async {
    if (throwOnReorder) throw Exception('offline');
    reorderedTo = List.of(order);
  }

  @override
  Future<void> deletePhotos({required List<ProfilePhoto> photos}) async {
    if (throwOnDelete) throw Exception('offline');
    deleted = List.of(photos);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<ProfilePhoto> _photos(int n) => [
  for (var i = 0; i < n; i++)
    ProfilePhoto(id: 'p$i', position: i, storagePath: 'avatars/user-1/p$i.jpg'),
];

/// Pushes [child] through a route so the screens' `Navigator.pop(true)` has
/// somewhere to go, and records what they popped with.
Future<List<bool?>> _pump(
  WidgetTester tester,
  _FakeProfileRepository repo,
  Widget child,
) async {
  final popped = <bool?>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [profileRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              popped.add(
                await Navigator.of(
                  context,
                ).push(MaterialPageRoute<bool>(builder: (_) => child)),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return popped;
}

/// `find.byTooltip` matches the Tooltip widget IconButton wraps its child in,
/// not the button itself — the button is its ancestor.
IconButton _deleteButton(WidgetTester tester) => tester.widget<IconButton>(
  find.ancestor(
    of: find.byTooltip('Delete'),
    matching: find.byType(IconButton),
  ),
);

void main() {
  group('delete screen', () {
    testWidgets('Delete is disabled until something is selected', (
      tester,
    ) async {
      final repo = _FakeProfileRepository();
      await _pump(tester, repo, ProfilePhotoDeleteScreen(photos: _photos(3)));

      expect(_deleteButton(tester).onPressed, isNull);
    });

    testWidgets('only the selected photos are deleted', (tester) async {
      final repo = _FakeProfileRepository();
      final photos = _photos(3);
      final popped = await _pump(
        tester,
        repo,
        ProfilePhotoDeleteScreen(photos: photos),
      );

      // Select the first and third tiles.
      await tester.tap(find.byKey(const ValueKey('p0')));
      await tester.tap(find.byKey(const ValueKey('p2')));
      await tester.pump();

      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(repo.deleted!.map((p) => p.id), ['p0', 'p2']);
      expect(popped, [true]);
    });

    testWidgets('tapping a selected photo again deselects it', (tester) async {
      final repo = _FakeProfileRepository();
      await _pump(tester, repo, ProfilePhotoDeleteScreen(photos: _photos(2)));

      await tester.tap(find.byKey(const ValueKey('p0')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('p0')));
      await tester.pump();

      expect(_deleteButton(tester).onPressed, isNull);
    });

    testWidgets('cancelling the confirmation deletes nothing', (tester) async {
      final repo = _FakeProfileRepository();
      await _pump(tester, repo, ProfilePhotoDeleteScreen(photos: _photos(2)));

      await tester.tap(find.byKey(const ValueKey('p0')));
      await tester.pump();
      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(repo.deleted, isNull);
    });

    testWidgets('a failed delete reports it and stays on the screen', (
      tester,
    ) async {
      final repo = _FakeProfileRepository()..throwOnDelete = true;
      final popped = await _pump(
        tester,
        repo,
        ProfilePhotoDeleteScreen(photos: _photos(2)),
      );

      await tester.tap(find.byKey(const ValueKey('p0')));
      await tester.pump();
      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(
        find.text('Failed to delete photos. Please try again.'),
        findsOneWidget,
      );
      // Nothing was popped: the user keeps their selection and can retry.
      expect(popped, isEmpty);
    });

    testWidgets('the grid is lazy, not a Wrap that builds all 80 at once', (
      tester,
    ) async {
      // Regression guard: this screen used to be a Wrap inside a
      // SingleChildScrollView, so opening it on a full gallery started 80
      // downloads and 80 decodes before a single tile was visible.
      final repo = _FakeProfileRepository();
      await _pump(tester, repo, ProfilePhotoDeleteScreen(photos: _photos(80)));

      expect(find.byType(GridView), findsOneWidget);
      expect(find.byType(Wrap), findsNothing);
      // Only a screenful (plus cache extent) is built, nowhere near all 80.
      final built = tester.widgetList(find.byKey(const ValueKey('p79'))).length;
      expect(built, 0, reason: 'the last tile must not be built up front');
    });
  });

  group('reorder screen', () {
    testWidgets('saving sends the whole gallery in its current order', (
      tester,
    ) async {
      final repo = _FakeProfileRepository();
      final photos = _photos(3);
      final popped = await _pump(
        tester,
        repo,
        ProfilePhotoReorderScreen(photos: photos),
      );

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      // Untouched order, but the whole list — the server rejects a partial
      // set with PT422, so "all of it" is the contract, not an accident.
      expect(repo.reorderedTo!.map((p) => p.id), ['p0', 'p1', 'p2']);
      expect(popped, [true]);
    });

    testWidgets('a failed save reports it and does not close the screen', (
      tester,
    ) async {
      final repo = _FakeProfileRepository()..throwOnReorder = true;
      final popped = await _pump(
        tester,
        repo,
        ProfilePhotoReorderScreen(photos: _photos(3)),
      );

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        find.text('Failed to reorder photos. Please try again.'),
        findsOneWidget,
      );
      expect(popped, isEmpty);
    });
  });
}
