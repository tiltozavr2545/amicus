import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:amicus/features/auth/auth_providers.dart';
import 'package:amicus/features/rooms/room_chat_screen.dart';
import 'package:amicus/features/rooms/rooms_repository.dart';
import 'package:amicus/l10n/app_localizations.dart';
import 'package:amicus/shared/media_picking.dart';
import 'package:amicus/shared/signed_url_cache.dart';

/// Only the members the chat screen calls need real behaviour; the rest
/// satisfy the `implements` contract via `noSuchMethod`, the same trick the
/// feed screen tests use.
class _FakeRoomsRepository implements RoomsRepository {
  _FakeRoomsRepository({this.messages = const []});

  List<RoomMessage> messages;

  int markReadCalls = 0;
  final List<String> sentTexts = [];
  final List<String> deletedIds = [];
  bool sendThrows = false;

  /// The screen's realtime handlers, captured so a test can play the part of
  /// the server and push a message in.
  void Function(RoomMessage)? onInsert;
  void Function(RoomMessage)? onUpdate;
  int unsubscribeCalls = 0;

  /// How many times the newest page was asked for — the catch-up after a
  /// re-subscription is exactly one such request.
  int firstPageFetches = 0;

  /// How many times a page of OLDER history was asked for. Zero is the right
  /// answer once a short page has said there is no more of it.
  int olderPageFetches = 0;

  bool fetchThrows = false;

  @override
  Future<List<RoomMessage>> fetchMessages({
    required String roomId,
    RoomMessage? before,
    int limit = 50,
  }) async {
    if (before != null) {
      olderPageFetches++;
      if (fetchThrows) throw Exception('offline');
      return const [];
    }
    firstPageFetches++;
    if (fetchThrows) throw Exception('offline');
    return messages;
  }

  /// Attachments each send carried — the attach button is only meaningful if
  /// what it collects reaches the repository.
  final List<List<PickedMedia>> sentMedia = [];

  /// `replyToId` each send carried, in order — null entries are plain
  /// messages, so a test can tell a reply's send apart from an ordinary one.
  final List<String?> sentReplyToIds = [];

  @override
  Future<RoomMessage> sendMessage({
    required String roomId,
    required String authorId,
    required String text,
    required String clientToken,
    List<PickedMedia> media = const [],
    String? replyToId,
  }) async {
    sentTexts.add(text);
    sentMedia.add(media);
    sentReplyToIds.add(replyToId);
    if (sendThrows) throw Exception('rejected');
    return RoomMessage(
      id: 'sent-${sentTexts.length}',
      roomId: roomId,
      authorId: authorId,
      text: text,
      createdAt: DateTime.utc(2026, 8, 26, 19),
      replyToId: replyToId,
      replyToPreview: replyToId == null
          ? null
          : replyPreviewFor(messages, replyToId),
    );
  }

  @override
  Future<void> deleteMessage(String messageId) async =>
      deletedIds.add(messageId);

  @override
  Future<void> markRoomRead(String roomId) async => markReadCalls++;

  /// The screen's catch-up hook, captured so a test can play the part of a
  /// channel that went down with the app and came back.
  void Function()? onResubscribed;

  @override
  void Function() subscribeToMessages({
    required String roomId,
    required void Function(RoomMessage message) onInsert,
    required void Function(RoomMessage message) onUpdate,
    required void Function() onResubscribed,
  }) {
    this.onInsert = onInsert;
    this.onUpdate = onUpdate;
    this.onResubscribed = onResubscribed;
    return () => unsubscribeCalls++;
  }

  /// Every batch of paths a round trip was actually spent on. The chat list
  /// recreates a bubble's `State` whenever a message is inserted above it, so
  /// "how many times was this photo signed" is precisely the question
  /// [SignedUrlCache] exists to answer — and the real repository answers it
  /// the same way this fake does.
  final List<List<String>> signedBatches = [];
  final Map<String, String> _signed = {};

  @override
  Future<Map<String, String>> resolveMediaUrls(List<String> paths) async {
    signedBatches.add(paths);
    for (final path in paths) {
      _signed[path] = 'https://example.invalid/$path';
    }
    return {for (final path in paths) path: _signed[path]!};
  }

  @override
  Map<String, String> cachedMediaUrls(List<String> paths) => {
    for (final path in paths)
      if (_signed[path] case final url?) path: url,
  };

  /// The screen's presence handler, captured so a test can play the part of
  /// the channel and say who is here and who is typing.
  void Function(Set<String> present, Set<String> typing)? onPresence;

  /// What the screen announced about itself, in order.
  final List<bool> typingAnnounced = [];
  int presenceUnsubscribeCalls = 0;

  /// The screen's answer to "is this viewer typing right now", captured so a
  /// test can play the part of a channel joining — which the real one does
  /// again on every rejoin, not only the first time.
  bool Function()? announceSelf;

  @override
  RoomPresenceHandle subscribeToPresence({
    required String roomId,
    required String userId,
    required void Function(Set<String> present, Set<String> typing) onChange,
    required bool Function() onSubscribed,
  }) {
    onPresence = onChange;
    announceSelf = onSubscribed;
    return RoomPresenceHandle(
      setTyping: (typing) async => typingAnnounced.add(typing),
      unsubscribe: () => presenceUnsubscribeCalls++,
    );
  }

  @override
  Future<List<RoomMemberReceipt>> fetchMemberReceipts(String roomId) async =>
      const [];

  @override
  void Function() subscribeToMemberReceipts({
    required String roomId,
    required void Function(RoomMemberReceipt receipt) onUpdate,
  }) => () {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RoomMessage _message({
  required String id,
  required String authorId,
  String text = 'привет',
  DateTime? createdAt,
  DateTime? deletedAt,
  List<RoomMessageMedia> media = const [],
  String? replyToId,
  RoomMessageReplyPreview? replyToPreview,
}) => RoomMessage(
  id: id,
  roomId: 'room-1',
  authorId: authorId,
  text: text,
  createdAt: createdAt ?? DateTime.utc(2026, 8, 26, 18),
  deletedAt: deletedAt,
  media: media,
  replyToId: replyToId,
  replyToPreview: replyToPreview,
);

/// What a real send's `reply_to` embed would resolve to, built from whatever
/// the fake repository already has loaded — the fake's stand-in for the
/// server-side join `RoomsRepository.sendMessage` relies on.
RoomMessageReplyPreview? replyPreviewFor(
  List<RoomMessage> messages,
  String id,
) {
  for (final m in messages) {
    if (m.id != id) continue;
    return RoomMessageReplyPreview(
      id: m.id,
      text: m.text,
      hasMedia: m.media.isNotEmpty,
      authorName: m.authorName,
      isDeleted: m.isDeleted,
    );
  }
  return null;
}

/// `_LinkifiedMessageText`'s rendered text — a `Text.rich`, distinguished
/// from every other `Text` on screen (all plain `Text.data`) by carrying a
/// `textSpan` instead.
Finder _linkifiedText() => find.byWidgetPredicate(
  (widget) => widget is Text && widget.textSpan != null,
);

/// A live message's own body text, wherever it appears on screen. Every
/// other `find.text(...)` target in this file — buttons, labels, a
/// tombstone, a reply preview's quote — still renders as exactly the string
/// it shows; only `_LinkifiedMessageText` no longer does, since it now ends
/// in an invisible separator marker (`_messageSeparator`; see there) that
/// makes an exact match fail.
Finder _messageText(String text) => find.textContaining(text);

final _room = Room(
  id: 'room-1',
  name: 'Дача',
  isDirect: false,
  ownerId: 'me',
  createdAt: DateTime.utc(2026, 8, 26),
  members: const [
    RoomMember(userId: 'me', name: 'Тимофей'),
    RoomMember(userId: 'anya', name: 'Аня'),
  ],
);

/// [showChat] off leaves the same `ProviderScope` — and so the same
/// container, and the same provider state — standing with the screen gone,
/// which is what "the viewer left the chat" actually looks like. Replacing
/// the whole tree would take the container with it and there would be
/// nothing left to assert about.
Widget _wrap(
  _FakeRoomsRepository repo, {
  List<Room> rooms = const [],
  bool showChat = true,
}) {
  return ProviderScope(
    overrides: [
      currentUserIdProvider.overrideWithValue('me'),
      roomsRepositoryProvider.overrideWithValue(repo),
      myRoomsProvider.overrideWith((ref) => rooms.isEmpty ? [_room] : rooms),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: showChat
          ? const RoomChatScreen(roomId: 'room-1')
          : const SizedBox.shrink(),
    ),
  );
}

void main() {
  testWidgets('shows the room name and its messages', (tester) async {
    final repo = _FakeRoomsRepository(
      messages: [
        _message(id: 'm2', authorId: 'me', text: 'моё сообщение'),
        _message(id: 'm1', authorId: 'anya', text: 'её сообщение'),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('Дача'), findsOneWidget);
    expect(_messageText('моё сообщение'), findsOneWidget);
    expect(_messageText('её сообщение'), findsOneWidget);
    // Someone else's message is signed; one's own is not — which side of the
    // screen it sits on already says who wrote it.
    expect(find.text('Аня'), findsOneWidget);
    expect(find.text('Тимофей'), findsNothing);
  });

  testWidgets('opening the chat marks it read', (tester) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(repo.markReadCalls, 1);
  });

  testWidgets('a deleted message is a tombstone, not a gap', (tester) async {
    final repo = _FakeRoomsRepository(
      messages: [
        _message(
          id: 'm1',
          authorId: 'anya',
          text: '',
          deletedAt: DateTime.utc(2026, 8, 26, 18, 5),
        ),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('Message deleted'), findsOneWidget);
  });

  testWidgets('someone typing is shown under the room name', (tester) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    repo.onPresence!({'me', 'anya'}, {'anya'});
    await tester.pump();

    // A group names who it is: "someone is typing" in a room of five says
    // almost nothing.
    expect(find.text('Аня is typing…'), findsOneWidget);
  });

  testWidgets('with nobody typing, presence says who is here', (tester) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    repo.onPresence!({'me', 'anya'}, const {});
    await tester.pump();

    // Counted, and the viewer is not in the count.
    expect(find.text('1 online'), findsOneWidget);
  });

  testWidgets('the viewer alone in the chat is not "online"', (tester) async {
    // Own presence is filtered out: telling someone they are online is noise.
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    repo.onPresence!({'me'}, {'me'});
    await tester.pump();

    expect(find.text('1 online'), findsNothing);
    expect(find.textContaining('typing'), findsNothing);
  });

  testWidgets('typing is announced once, and taken back on send', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'п');
    await tester.enterText(find.byType(TextField), 'при');
    await tester.pump();
    // Per state, not per keystroke.
    expect(repo.typingAnnounced, [true]);

    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(repo.typingAnnounced, [true, false]);
  });

  testWidgets('a join announces the draft rather than wiping it', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    // The channel is still joining; this announcement is buffered by the
    // channel, not lost.
    await tester.enterText(find.byType(TextField), 'пишу');
    await tester.pump();
    expect(repo.typingAnnounced, [true]);

    // The join lands. It used to track a hardcoded `typing: false` here,
    // which overwrote the buffered "typing" AND left the screen believing it
    // had announced one — so no later keystroke ever re-raised it.
    expect(repo.announceSelf!(), isTrue);

    await tester.enterText(find.byType(TextField), 'пишу дальше');
    await tester.pump();
    // Still the one announcement: the state never changed, and the join
    // agreed with it instead of contradicting it.
    expect(repo.typingAnnounced, [true]);
  });

  testWidgets('a rejoin puts the announcement back in sync', (tester) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'пишу');
    await tester.pump();
    expect(repo.typingAnnounced, [true]);

    // The socket went down with the app and came back on a fresh channel,
    // which carries nothing over — and by then the draft is gone.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(repo.announceSelf!(), isFalse);

    // In sync again: the next draft raises the indicator instead of being
    // skipped as something already announced.
    await tester.enterText(find.byType(TextField), 'снова');
    await tester.pump();
    expect(repo.typingAnnounced, [true, false, true]);
  });

  testWidgets('a channel that is no longer up takes "online" with it', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    repo.onPresence!({'me', 'anya'}, const {});
    await tester.pump();
    expect(find.text('1 online'), findsOneWidget);

    // What the repository reports when the channel errors, times out or
    // closes: presence is a claim about right now, and there is no longer a
    // channel making it true.
    repo.onPresence!(const {}, const {});
    await tester.pump();

    expect(find.text('1 online'), findsNothing);
  });

  testWidgets('a message can be attachments with no caption at all', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository(
      messages: [
        _message(
          id: 'm1',
          authorId: 'anya',
          text: '',
          media: const [
            RoomMessageMedia(
              storagePath: 'messages/room-1/anya/t/a.jpg',
              isVideo: false,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pump();

    // The bubble is the photo: attachments rendered, and no caption line
    // where there is no caption (the tombstone label is the only text a
    // bubble ever shows in place of one).
    expect(find.byKey(const ValueKey('message-media-m1')), findsOneWidget);
    expect(find.text('Message deleted'), findsNothing);
  });

  testWidgets('an arriving message does not re-sign the photos on screen', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository(
      messages: [
        _message(
          id: 'm1',
          authorId: 'anya',
          text: '',
          media: const [
            RoomMessageMedia(
              storagePath: 'messages/room-1/anya/t/a.jpg',
              isVideo: false,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(repo.signedBatches, hasLength(1));

    // Inserting at the top shifts every index below it, and the list has no
    // `findChildIndexCallback` to offer, so this bubble's attachment `State`
    // is rebuilt from scratch. It must come back with the URL it already had
    // rather than a spinner and a second round trip.
    repo.onInsert!(_message(id: 'live-1', authorId: 'anya', text: 'и ещё'));
    await tester.pumpAndSettle();

    expect(_messageText('и ещё'), findsOneWidget);
    expect(repo.signedBatches, hasLength(1));
  });

  testWidgets('sending posts the text and clears the field', (tester) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '  до встречи  ');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(repo.sentTexts, ['до встречи']);
    expect(_messageText('до встречи'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
  });

  testWidgets('an empty message is not sent', (tester) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(repo.sentTexts, isEmpty);
  });

  testWidgets('a failed send keeps the draft and says so', (tester) async {
    final repo = _FakeRoomsRepository()..sendThrows = true;
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'не уйдёт');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.text('Failed to send. Please try again.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'не уйдёт',
    );
  });

  testWidgets('a message arriving over realtime appears in the list', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    repo.onInsert!(
      _message(id: 'live-1', authorId: 'anya', text: 'только что пришло'),
    );
    await tester.pumpAndSettle();

    expect(_messageText('только что пришло'), findsOneWidget);
    // Reading a room while looking at it is what silences its pushes.
    expect(repo.markReadCalls, 2);
  });

  testWidgets('the echo of an own message does not duplicate it', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'одно сообщение');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    // The sender's own insert comes back over the subscription too.
    repo.onInsert!(
      _message(id: 'sent-1', authorId: 'me', text: 'одно сообщение'),
    );
    await tester.pumpAndSettle();

    expect(_messageText('одно сообщение'), findsOneWidget);
  });

  testWidgets('day separators use relative labels for recent days', (
    tester,
  ) async {
    // Anchored to `now` rather than fixed dates: the boundary check is
    // "same calendar day as today/yesterday", which a hardcoded date would
    // only happen to satisfy on the day this test was written.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 10);
    final yesterday = today.subtract(const Duration(days: 1));
    final lastWeek = today.subtract(const Duration(days: 8));

    final repo = _FakeRoomsRepository(
      messages: [
        _message(id: 'm3', authorId: 'me', text: 'сегодня', createdAt: today),
        _message(
          id: 'm2',
          authorId: 'anya',
          text: 'вчера',
          createdAt: yesterday,
        ),
        _message(
          id: 'm1',
          authorId: 'anya',
          text: 'на прошлой неделе',
          createdAt: lastWeek,
        ),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(
      find.text(DateFormat('d MMM y', 'en').format(lastWeek)),
      findsOneWidget,
    );
  });

  testWidgets('messages from the same day share one separator', (tester) async {
    final now = DateTime.now();
    final repo = _FakeRoomsRepository(
      messages: [
        _message(
          id: 'm2',
          authorId: 'me',
          text: 'второе',
          createdAt: DateTime(now.year, now.month, now.day, 18),
        ),
        _message(
          id: 'm1',
          authorId: 'anya',
          text: 'первое',
          createdAt: DateTime(now.year, now.month, now.day, 9),
        ),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets('tapping a message offers to reply to it', (tester) async {
    final repo = _FakeRoomsRepository(
      messages: [_message(id: 'm1', authorId: 'anya', text: 'оригинал')],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(_messageText('оригинал'));
    await tester.pumpAndSettle();

    expect(find.text('Reply'), findsOneWidget);
    // Not the viewer's own message, so no delete option.
    expect(find.text('Delete'), findsNothing);

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    expect(find.text('Replying to: Аня'), findsOneWidget);
  });

  testWidgets('the close button on the reply preview cancels it', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository(
      messages: [_message(id: 'm1', authorId: 'anya', text: 'оригинал')],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(_messageText('оригинал'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(find.text('Replying to: Аня'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('Replying to: Аня'), findsNothing);
  });

  testWidgets('a deleted message offers no tap actions', (tester) async {
    final repo = _FakeRoomsRepository(
      messages: [
        _message(
          id: 'm1',
          authorId: 'anya',
          text: '',
          deletedAt: DateTime.utc(2026, 8, 26, 18, 5),
        ),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Message deleted'));
    await tester.pumpAndSettle();

    expect(find.text('Reply'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('long-pressing message text does not open the actions sheet', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository(
      messages: [_message(id: 'm1', authorId: 'anya', text: 'оригинал')],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.longPress(_messageText('оригинал'));
    await tester.pumpAndSettle();

    // A long press is what the list's `SelectionArea` listens for to start a
    // word selection — a tap is what opens the sheet (see the comment on
    // `_MessageBubble`'s `GestureDetector`), and the two gestures resolve
    // independently, so this must not also open it.
    expect(find.text('Reply'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('a URL in message text is styled distinctly and tappable', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository(
      messages: [
        _message(id: 'm1', authorId: 'anya', text: 'https://example.com'),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    final richText = tester.widget<Text>(_linkifiedText());
    // The link span, then the invisible separator marker every message ends
    // in (see `_LinkifiedMessageText._buildSpans`) — not part of this check.
    final span = (richText.textSpan! as TextSpan).children!.first as TextSpan;
    expect(span.text, 'https://example.com');
    expect(span.recognizer, isNotNull);
    expect(span.style?.decoration, TextDecoration.underline);
  });

  testWidgets('tapping a link opens it, not the actions sheet', (tester) async {
    final repo = _FakeRoomsRepository(
      messages: [
        _message(id: 'm1', authorId: 'anya', text: 'https://example.com'),
      ],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    // The link's own recognizer wins the tap over the bubble's — a pointer
    // gesture resolves to exactly one recognizer — so this must not also
    // open the sheet. `url_launcher` itself isn't mocked here, but
    // `_LinkifiedMessageText._openLink` catches a failed launch, so the tap
    // settling without the sheet appearing is what this checks.
    await tester.tap(_messageText('https://example.com'));
    await tester.pumpAndSettle();

    expect(find.text('Reply'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets(
    'copying a selection spanning two messages joins them with a real '
    'line break',
    (tester) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              copiedText = (call.arguments as Map)['text'] as String?;
            case 'Clipboard.getData':
              return <String, dynamic>{'text': copiedText};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      // Newest first, same as every other fixture in this file: with
      // `reverse: true` that's what puts the newest message at the bottom
      // of the screen, oldest at the top — ordinary chat reading order.
      final repo = _FakeRoomsRepository(
        messages: [
          _message(
            id: 'm2',
            authorId: 'anya',
            text: 'второе',
            createdAt: DateTime.utc(2026, 8, 26, 19),
          ),
          _message(
            id: 'm1',
            authorId: 'anya',
            text: 'первое',
            createdAt: DateTime.utc(2026, 8, 26, 18),
          ),
        ],
      );
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      // Drag from inside the older message to inside the newer one — top to
      // bottom on screen, same as the app always shows them.
      final startPos =
          tester.getTopLeft(_messageText('первое')) + const Offset(2, 8);
      final endPos =
          tester.getBottomRight(_messageText('второе')) - const Offset(2, 4);
      final gesture = await tester.startGesture(startPos);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(endPos);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      expect(copiedText, 'первое\nвторое');
    },
  );

  testWidgets('sending a reply carries its target and quotes it', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository(
      messages: [_message(id: 'm1', authorId: 'anya', text: 'оригинал')],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.tap(_messageText('оригинал'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ответ');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(repo.sentReplyToIds, ['m1']);
    // Sending clears reply mode, same as it clears the text field.
    expect(find.text('Replying to: Аня'), findsNothing);
    expect(_messageText('ответ'), findsOneWidget);
    // The quote appears twice: the original message's own bubble, and the
    // snippet quoted inside the new reply's bubble.
    expect(_messageText('оригинал'), findsNWidgets(2));
  });

  testWidgets('a reply whose target has not been loaded shows "unavailable"', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    repo.onInsert!(
      _message(
        id: 'live-1',
        authorId: 'anya',
        text: 'ответ на что-то старое',
        replyToId: 'missing-id',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Original message unavailable'), findsOneWidget);
  });

  testWidgets('a page shorter than a full one ends the history', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository(
      messages: [_message(id: 'm1', authorId: 'anya', text: 'всё, что есть')],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    // This used to read "there is more unless the page came back empty", so
    // every chat spent one extra round trip asking for history that a short
    // page had already ruled out.
    expect(repo.olderPageFetches, 0);
  });

  testWidgets('a failed load backs off instead of retrying at once', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository()..fetchThrows = true;
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();
    expect(repo.firstPageFetches, 1);

    // Coming back to the app asks again — but the last failure was a moment
    // ago, and the trigger behind this fires on every frame of every scroll.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(repo.firstPageFetches, 1);
  });

  testWidgets('a channel coming back picks up what was missed', (tester) async {
    final repo = _FakeRoomsRepository(
      messages: [_message(id: 'm1', authorId: 'anya', text: 'до')],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();
    expect(repo.firstPageFetches, 1);

    // Said while the socket was down — which it is every time the app is
    // backgrounded. Postgres Changes does not replay, so nothing will ever
    // deliver this; only re-reading the newest page can find it.
    repo.messages = [
      _message(id: 'm2', authorId: 'anya', text: 'пока тебя не было'),
      _message(id: 'm1', authorId: 'anya', text: 'до'),
    ];
    repo.onResubscribed!();
    await tester.pumpAndSettle();

    expect(repo.firstPageFetches, 2);
    expect(_messageText('пока тебя не было'), findsOneWidget);
    // Stitched, not replaced: the message that was already here is still
    // here, exactly once.
    expect(_messageText('до'), findsOneWidget);
  });

  testWidgets('a deletion that happened while away lands as a tombstone', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository(
      messages: [_message(id: 'm1', authorId: 'anya', text: 'зря написал')],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();
    expect(_messageText('зря написал'), findsOneWidget);

    // A delete arrives as an edit to a row already on screen, so it is not
    // something a "what is newer than my newest" query would ever find —
    // which is why the catch-up re-reads the page rather than the tail.
    repo.messages = [
      _message(
        id: 'm1',
        authorId: 'anya',
        text: '',
        deletedAt: DateTime.utc(2026, 8, 26, 18, 5),
      ),
    ];
    repo.onResubscribed!();
    await tester.pumpAndSettle();

    expect(_messageText('зря написал'), findsNothing);
    expect(find.text('Message deleted'), findsOneWidget);
  });

  testWidgets('a gap too big to stitch restarts the list instead', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository(
      messages: [_message(id: 'm1', authorId: 'anya', text: 'старое')],
    );
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    // Not one id in common: a page's worth arrived and there may be more
    // still between this page and what is loaded. Stitching would put a
    // silent hole in the middle of the conversation.
    repo.messages = [
      _message(id: 'n2', authorId: 'anya', text: 'второе новое'),
      _message(id: 'n1', authorId: 'anya', text: 'первое новое'),
    ];
    repo.onResubscribed!();
    await tester.pumpAndSettle();

    expect(_messageText('первое новое'), findsOneWidget);
    expect(_messageText('второе новое'), findsOneWidget);
    expect(_messageText('старое'), findsNothing);
  });

  testWidgets('arriving messages do not refetch the room list; leaving does', (
    tester,
  ) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(RoomChatScreen)),
    );
    final atOpen = container.read(roomsRefreshTickProvider);

    repo.onInsert!(_message(id: 'live-1', authorId: 'anya', text: 'раз'));
    await tester.pumpAndSettle();
    repo.onInsert!(_message(id: 'live-2', authorId: 'anya', text: 'два'));
    await tester.pumpAndSettle();

    // Every message still moves the read mark — that is what silences the
    // room's pushes and flips the other side's tick. What it no longer does
    // is refetch the whole room list behind this screen, three round trips
    // and a realtime fan-out at a time.
    expect(repo.markReadCalls, 3);
    expect(container.read(roomsRefreshTickProvider), atOpen);

    await tester.pumpWidget(_wrap(repo, showChat: false));
    await tester.pumpAndSettle();

    // Once, on the way out, when the list is about to be looked at again.
    expect(container.read(roomsRefreshTickProvider), atOpen + 1);
  });

  testWidgets('leaving the screen unsubscribes', (tester) async {
    final repo = _FakeRoomsRepository();
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(repo.unsubscribeCalls, 1);
    // Presence too: without this the viewer stays "in the chat" in a room
    // nobody has open.
    expect(repo.presenceUnsubscribeCalls, 1);
  });
}
