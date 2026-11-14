import 'dart:io';
import 'dart:ui' as ui;

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/auth/sign_in_screen.dart';
import 'package:amicus/features/connections/connections_repository.dart';
import 'package:amicus/features/connections/connections_screen.dart';
import 'package:amicus/features/connections/friend_profile_screen.dart';
import 'package:amicus/features/feed/feed_repository.dart';
import 'package:amicus/features/feed/post_draft_store.dart';
import 'package:amicus/features/feed/feed_screen.dart';
import 'package:amicus/features/feed/comments_screen.dart';
import 'package:amicus/features/notifications/push_deep_link.dart';
import 'package:amicus/features/notifications/push_notifications_repository.dart';
import 'package:amicus/features/notifications/user_activity_repository.dart';
import 'package:amicus/features/profile/profile_repository.dart';
import 'package:amicus/features/profile/profile_screen.dart';
import 'package:amicus/features/rooms/rooms_repository.dart';
import 'package:amicus/features/rooms/rooms_screen.dart';
import 'package:amicus/features/rooms/room_chat_screen.dart';
import 'package:amicus/features/settings/notification_preferences_repository.dart';
import 'package:amicus/features/settings/settings_screen.dart';
import 'package:amicus/features/shell/main_shell_screen.dart';
import 'package:amicus/features/shell/navigation_motion.dart';
import 'package:amicus/l10n/app_localizations.dart';
import 'package:amicus/theme/amicus_theme.dart';
import 'package:amicus/theme/theme_mode_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Drafts extends PostDraftStore {
  @override
  Future<PostDraft?> load(String user) async => null;
  @override
  Future<void> save(String user, PostDraft draft) async {}
  @override
  Future<void> clear(String user) async {}
}

class _Feed implements FeedRepository {
  @override
  Future<CommentPage> fetchComments(String postId) async =>
      CommentPage(comments: [], isTruncated: false);
  @override
  Future<List<Post>> fetchPage({
    Post? cursor,
    String? authorId,
    Set<String> mutedAuthorIds = const {},
  }) async => cursor != null
      ? []
      : [
          Post(
            id: 'post',
            authorId: 'anna',
            authorName: 'Анна Лебедева',
            createdAt: DateTime(2026, 11, 14, 12, 30),
            text:
                'В субботу снова идём к озеру. Берите термос — на берегу уже холодно. Кто с нами?',
            likeCount: 4,
            commentCount: 2,
          ),
          Post(
            id: 'second',
            authorId: 'max',
            authorName: 'Максим',
            createdAt: DateTime(2026, 11, 14, 10, 15),
            text:
                'Нашёл фотографии с прошлой встречи. Как же хорошо было собраться вместе.',
          ),
        ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connections implements ConnectionsRepository {
  @override
  Future<Set<String>> fetchMutedIds(String userId) async => {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Profile implements ProfileRepository {
  @override
  Future<Profile> fetchProfile(String userId) async =>
      Profile(id: userId, name: 'Алексей');

  @override
  Future<List<ProfilePhoto>> fetchPhotos(String userId) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Rooms implements RoomsRepository {
  @override
  Future<List<RoomMessage>> fetchMessages({
    required String roomId,
    RoomMessage? before,
    int limit = 50,
  }) async => [];

  @override
  Future<void> markRoomRead(String roomId) async {}

  @override
  Future<List<RoomMemberReceipt>> fetchMemberReceipts(String roomId) async =>
      [];

  @override
  void Function() subscribeToMessages({
    required String roomId,
    required void Function(RoomMessage) onInsert,
    required void Function(RoomMessage) onUpdate,
    required void Function() onResubscribed,
  }) => () {};

  @override
  void Function() subscribeToMemberReceipts({
    required String roomId,
    required void Function(RoomMemberReceipt) onUpdate,
    required void Function() onResubscribed,
  }) => () {};

  @override
  RoomPresenceHandle subscribeToPresence({
    required String roomId,
    required String userId,
    required void Function(Set<String>, Set<String>) onChange,
    required bool Function() onSubscribed,
  }) => RoomPresenceHandle(setTyping: (_) async {}, unsubscribe: () {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifications implements NotificationPreferencesRepository {
  @override
  Future<NotificationPreferences> fetch(String userId) async =>
      const NotificationPreferences();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _rooms = [
  Room(
    id: 'room',
    isDirect: false,
    name: 'На выходных',
    ownerId: 'me',
    createdAt: DateTime(2026),
    lastMessageText: 'Встречаемся в десять?',
    lastMessageAuthorId: 'anna',
    unreadCount: 3,
    members: const [
      RoomMember(userId: 'me', name: 'Алексей'),
      RoomMember(userId: 'anna', name: 'Анна'),
    ],
  ),
];

const _previewKey = ValueKey('interface-preview');

/// Optional local design artifacts; never contacts or content from a real account.
Future<void> _preview(WidgetTester tester, String name) async {
  const directory = String.fromEnvironment('AMICUS_PREVIEW_DIR');
  if (directory.isEmpty) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_previewKey),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    await initializeDateFormatting('ru');
    final fonts = FontLoader('Sofia Sans');
    for (final weight in [400, 500, 600, 700]) {
      fonts.addFont(rootBundle.load('assets/fonts/SofiaSans-$weight.ttf'));
    }
    await fonts.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final dark in [false, true]) {
    for (final width in [320.0, 390.0, 800.0]) {
      testWidgets('Main screens fit $width with Russian text, dark=$dark', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(bottom: 24);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final router = GoRouter(
          routes: [
            StatefulShellRoute(
              navigatorContainerBuilder: (_, shell, children) =>
                  NavigationPages(shell: shell, children: children),
              builder: (_, _, shell) => MainShellScreen(navigationShell: shell),
              branches: [
                for (final (path, screen) in <(String, Widget)>[
                  ('/', const FeedScreen()),
                  ('/rooms', const RoomsScreen()),
                  ('/connections', const ConnectionsScreen()),
                  ('/profile', const ProfileScreen()),
                ])
                  StatefulShellBranch(
                    preload: true,
                    routes: [GoRoute(path: path, builder: (_, _) => screen)],
                  ),
              ],
            ),
            GoRoute(
              path: '/settings',
              builder: (_, _) => const SettingsScreen(),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserIdProvider.overrideWithValue('me'),
              feedRepositoryProvider.overrideWithValue(_Feed()),
              postDraftStoreProvider.overrideWithValue(_Drafts()),
              profileRepositoryProvider.overrideWithValue(_Profile()),
              notificationPreferencesRepositoryProvider.overrideWithValue(
                _Notifications(),
              ),
              connectionsRepositoryProvider.overrideWithValue(_Connections()),
              connectionRequestsProvider.overrideWith((ref) async => []),
              friendsProvider.overrideWith(
                (ref) async => [
                  Friend(
                    userId: 'anna',
                    name: 'Анна Лебедева',
                    connectedAt: DateTime(2026, 2, 1),
                  ),
                ],
              ),
              myRoomsProvider.overrideWith((ref) async => _rooms),
              roomsRepositoryProvider.overrideWithValue(_Rooms()),
              pushRegistrationProvider.overrideWith((ref) async {}),
              userActivityProvider.overrideWith((ref) async {}),
              pushTapsProvider.overrideWith((ref) => const Stream.empty()),
            ],
            child: RepaintBoundary(
              key: _previewKey,
              child: Consumer(
                builder: (context, ref, _) => MaterialApp.router(
                  debugShowCheckedModeBanner: false,
                  locale: const Locale('ru'),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  theme: AmicusTheme.light,
                  darkTheme: AmicusTheme.dark,
                  themeMode: ref.watch(themeModeProvider) == ThemeMode.system
                      ? (dark ? ThemeMode.dark : ThemeMode.light)
                      : ref.watch(themeModeProvider),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(width == 390 ? 1 : 1.3),
                    ),
                    child: child!,
                  ),
                  routerConfig: router,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final suffix = '${width.toInt()}-${dark ? 'dark' : 'light'}';
        expect(find.text('Анна Лебедева'), findsOneWidget);
        expect(find.textContaining('В субботу'), findsOneWidget);
        await tester.tap(find.text('Анна Лебедева').first);
        await tester.pumpAndSettle();
        expect(find.byType(FriendProfileScreen), findsOneWidget);
        expect(find.byKey(const ValueKey('amicus-navigation')), findsNothing);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await _preview(tester, 'feed-$suffix');
        final bar = find.byKey(const ValueKey('amicus-navigation'));
        Future<void> checkTail(Finder last) async {
          await tester.drag(
            find.byType(Scrollable).hitTestable().first,
            const Offset(0, -4000),
          );
          await tester.pumpAndSettle();
          expect(
            tester.getRect(last).bottom,
            lessThanOrEqualTo(tester.getRect(bar).top),
            reason: 'The last control must clear the bar and device safe area',
          );
        }

        await checkTail(find.byTooltip('Комментарии').last);
        await tester.tap(find.byTooltip('Комментарии').last);
        await tester.pumpAndSettle();
        expect(find.byType(CommentsScreen), findsOneWidget);
        expect(bar, findsNothing);
        expect(
          tester.getRect(find.byType(TextField)).bottom,
          lessThanOrEqualTo(820),
        );
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        final barRect = tester.getRect(bar);
        await tester.dragFrom(
          barRect.topLeft + const Offset(28, 34),
          Offset(barRect.width * .4, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('На выходных'), findsOneWidget);
        expect(
          tester.getRect(find.byType(FloatingActionButton)).bottom,
          lessThanOrEqualTo(tester.getRect(bar).top),
          reason: 'The room creation action must clear the floating navigation',
        );
        await _preview(tester, 'rooms-$suffix');
        await tester.tap(find.text('На выходных'));
        await tester.pumpAndSettle();
        expect(find.byType(RoomChatScreen), findsOneWidget);
        expect(bar, findsNothing);
        await _preview(tester, 'chat-$suffix');
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(bar, findsOneWidget);
        await tester.drag(
          find.byKey(const ValueKey('tab-page-swipe')),
          Offset(-width * .8, 0),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ConnectionsScreen), findsOneWidget);
        final gesture = await tester.startGesture(tester.getRect(bar).center);
        await gesture.moveBy(Offset(tester.getRect(bar).width * .22, 0));
        await tester.pump();
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(find.byType(ConnectionsScreen), findsOneWidget);
        await tester.tap(find.byTooltip('Новый пост'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
        await _preview(tester, 'compose-$suffix');
        await checkTail(find.widgetWithText(FilledButton, 'Опубликовать'));
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        await tester.drag(
          find.byType(Scrollable).hitTestable().first,
          const Offset(0, -4000),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .getRect(find.widgetWithText(FilledButton, 'Опубликовать'))
              .bottom,
          lessThanOrEqualTo(544),
        );
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Профиль'));
        await tester.pumpAndSettle();
        await _preview(tester, 'profile-$suffix');
        await tester.tap(find.byTooltip('Знакомства'));
        await tester.pumpAndSettle();
        await _preview(tester, 'connections-$suffix');
        await checkTail(find.text('Анна Лебедева'));
        await tester.tap(find.text('Анна Лебедева'));
        await tester.pumpAndSettle();
        expect(find.byType(FriendProfileScreen), findsOneWidget);
        expect(bar, findsNothing);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(bar, findsOneWidget);
        router.go('/settings');
        await tester.pumpAndSettle();
        expect(bar, findsNothing);
        final theme = find.byType(DropdownButton<ThemeMode>);
        await tester.scrollUntilVisible(theme, 200);
        await tester.ensureVisible(theme);
        await tester.pumpAndSettle();
        await _preview(tester, 'settings-$suffix');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('Sign in scrolls above the keyboard in landscape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: RepaintBoundary(
          key: _previewKey,
          child: MaterialApp(
            theme: AmicusTheme.light,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SignInScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.widgetWithText(FilledButton, 'Sign in')).bottom,
      lessThanOrEqualTo(180),
    );
    expect(tester.takeException(), isNull);
  });
}
