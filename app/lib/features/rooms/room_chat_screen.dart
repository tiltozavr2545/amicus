import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/media_gallery.dart';
import '../../shared/media_pick_message.dart';
import '../../shared/media_picking.dart';
import '../../shared/sized_memory_image.dart';
import '../auth/auth_providers.dart';
import 'room_details_screen.dart';
import 'rooms_repository.dart';

/// How long after the last keystroke this viewer stops being "typing".
///
/// Long enough to survive a pause for thought, short enough that a draft
/// abandoned mid-word doesn't leave a lie on someone else's screen. The flag
/// is also cleared on send and on leaving the screen — this timer is only
/// for the case where neither happens.
const _typingIdleTimeout = Duration(seconds: 4);

/// How many photos/videos one message may carry. Mirrors the CHECK on
/// `room_messages.media` (20260828120000) — the server refuses an eleventh,
/// and being told so after the upload would be a wasted upload.
const _maxAttachments = 10;

/// A room's chat: everyone in the room reads and writes, nobody else can do
/// either — the RLS policy on `room_messages` decides that, and the same
/// policy is applied to the realtime subscription per subscriber.
///
/// Mute and block deliberately do not apply inside a room, so this list has no
/// holes in it: a conversation with someone's half missing reads worse than a
/// conversation with someone you'd rather not hear from.
class RoomChatScreen extends ConsumerStatefulWidget {
  const RoomChatScreen({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<RoomChatScreen> createState() => _RoomChatScreenState();
}

class _RoomChatScreenState extends ConsumerState<RoomChatScreen> {
  final _scrollController = ScrollController();
  final _textController = TextEditingController();

  /// Newest first — the list is `reverse: true`, so index 0 sits at the
  /// bottom where a chat's newest message belongs, and "load older" is the
  /// same "near the end of the scroll" gesture the feed already uses.
  final _messages = <RoomMessage>[];

  void Function()? _unsubscribe;
  void Function()? _unsubscribeReceipts;
  bool _isLoading = false;
  bool _hasMore = true;
  bool _isSending = false;
  bool _isPicking = false;
  String? _errorMessage;

  /// Files picked for the message being typed, in the order they will be
  /// sent. They are uploaded on send, not on pick: a draft abandoned before
  /// sending should cost the bucket nothing.
  final _attachments = <PickedMedia>[];

  /// The `client_token` of the draft currently in the composer, minted lazily
  /// on the first send attempt and kept until it either lands or the draft
  /// changes.
  ///
  /// A retry has to reuse this rather than minting its own: `.timeout()`
  /// stops [_send] waiting on a slow request without cancelling it, so on a
  /// bad connection the abandoned insert can still land after the client has
  /// already shown an error — and since the text field is deliberately left
  /// as-is on failure (see [_send]'s catch branch), a user who simply taps
  /// send again is retrying the same draft, not writing a new one. A fresh
  /// token there would dodge `room_messages`' own `client_token` unique index
  /// and post the same line twice.
  String? _pendingSendToken;

  RoomPresenceHandle? _presence;

  /// Everyone in this chat right now and everyone typing in it, the viewer
  /// included — filtered out where it is shown, since only the screen knows
  /// who is looking.
  Set<String> _present = const {};
  Set<String> _typing = const {};

  /// What this viewer last announced, so a keystroke doesn't re-announce
  /// "typing" on every character.
  bool _announcedTyping = false;
  Timer? _typingTimer;

  /// Every member's read/delivered marks, keyed by user id — what draws the
  /// ticks on the viewer's own messages. Absent while the first fetch is
  /// still in flight; a bubble with no entry for a member just shows no
  /// status yet rather than guessing.
  Map<String, RoomMemberReceipt> _receipts = {};

  @override
  void initState() {
    super.initState();
    _loadMore();
    _subscribe();
    _loadReceipts();
    _subscribeReceipts();
    // Opening the chat is reading it. This also silences the room's pushes
    // while the screen is up: the server skips a member whose read mark is
    // fresher than a minute, and every arriving message moves it again.
    _markRead();
    _subscribePresence();
    _textController.addListener(_onTyping);
    _scrollController.addListener(() {
      final nearEnd =
          _scrollController.position.pixels >
          _scrollController.position.maxScrollExtent - 200;
      if (nearEnd) _loadMore();
    });
  }

  @override
  void dispose() {
    // Unsubscribing is not optional: the channel outlives this State
    // otherwise, and its callbacks would call setState on a dead widget.
    _unsubscribe?.call();
    _unsubscribeReceipts?.call();
    // Leaving the screen is leaving the chat: without this the viewer stays
    // "present" in a room nobody has open, and "typing" can outlive the
    // draft that caused it.
    _typingTimer?.cancel();
    _presence?.unsubscribe();
    _scrollController.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _subscribe() {
    _unsubscribe = ref
        .read(roomsRepositoryProvider)
        .subscribeToMessages(
          roomId: widget.roomId,
          onInsert: (message) {
            if (!mounted) return;
            // The sender already inserted its own message from [_send] — the
            // echo of it arrives here too, and without this check it would
            // appear twice.
            if (_messages.any((m) => m.id == message.id)) return;
            setState(() => _messages.insert(0, message));
            _markRead();
          },
          onUpdate: (message) {
            if (!mounted) return;
            final index = _messages.indexWhere((m) => m.id == message.id);
            if (index == -1) return;
            setState(() => _messages[index] = message);
          },
        );
  }

  void _subscribePresence() {
    final viewerId = ref.read(currentUserIdProvider);
    if (viewerId == null) return;
    _presence = ref
        .read(roomsRepositoryProvider)
        .subscribeToPresence(
          roomId: widget.roomId,
          userId: viewerId,
          onChange: (present, typing) {
            if (!mounted) return;
            setState(() {
              _present = present;
              _typing = typing;
            });
          },
        );
  }

  /// Announces "typing" while there is something to type, and takes it back
  /// [_typingIdleTimeout] after the last keystroke.
  void _onTyping() {
    // The draft just changed (including being cleared after a send), so a
    // token minted for whatever it said before no longer describes it.
    _pendingSendToken = null;
    final typing = _textController.text.trim().isNotEmpty;
    _typingTimer?.cancel();
    if (typing) {
      _typingTimer = Timer(_typingIdleTimeout, () => _announceTyping(false));
    }
    _announceTyping(typing);
  }

  void _announceTyping(bool typing) {
    if (typing == _announcedTyping) return;
    _announcedTyping = typing;
    // Fire-and-forget: an announcement that doesn't land costs an indicator
    // nobody was promised, and there is nothing to report to.
    unawaited(_presence?.setTyping(typing).catchError((Object _) {}));
  }

  /// The line under the room's name: who is typing, or who is here.
  ///
  /// Typing wins over presence — it is the more specific fact, and it is the
  /// one worth watching. In a two-person room neither needs a name (there is
  /// only one other person); in a group both are named, because "someone is
  /// typing" in a room of five says almost nothing.
  String? _presenceLine(AppLocalizations l10n, Room? room, String? viewerId) {
    if (room == null) return null;
    final others = {
      for (final member in room.othersThan(viewerId)) member.userId,
    };
    final typing = _typing.intersection(others);
    final present = _present.intersection(others);

    if (typing.isNotEmpty) {
      if (room.isDirect || typing.length > 1) {
        return typing.length > 1
            ? l10n.severalTypingStatus(typing.length)
            : l10n.typingStatus;
      }
      final name = room.memberById(typing.first)?.name;
      return name == null ? l10n.typingStatus : l10n.someoneTypingStatus(name);
    }
    if (present.isEmpty) return null;
    return room.isDirect
        ? l10n.onlineStatus
        : l10n.onlineCountStatus(present.length);
  }

  Future<void> _markRead() async {
    try {
      await ref.read(roomsRepositoryProvider).markRoomRead(widget.roomId);
      // The unread badge in the room list is now wrong by exactly this room.
      ref.read(roomsRefreshTickProvider.notifier).bump();
    } catch (_) {
      // Best effort by design: failing to move a read mark is not worth a
      // message on screen, and the next open tries again.
    }
  }

  Future<void> _loadReceipts() async {
    try {
      final receipts = await ref
          .read(roomsRepositoryProvider)
          .fetchMemberReceipts(widget.roomId);
      if (!mounted) return;
      setState(() {
        _receipts = {for (final r in receipts) r.userId: r};
      });
    } catch (_) {
      // Best effort, same reasoning as `_markRead`: a stale tick is not
      // worth a message on screen, and the next open tries again.
    }
  }

  void _subscribeReceipts() {
    _unsubscribeReceipts = ref
        .read(roomsRepositoryProvider)
        .subscribeToMemberReceipts(
          roomId: widget.roomId,
          onUpdate: (receipt) {
            if (!mounted) return;
            setState(() => _receipts[receipt.userId] = receipt);
          },
        );
  }

  Future<void> _loadMore() async {
    if (_isLoading || !_hasMore) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final page = await ref
          .read(roomsRepositoryProvider)
          .fetchMessages(
            roomId: widget.roomId,
            before: _messages.isEmpty ? null : _messages.last,
          );
      if (!mounted) return;
      setState(() {
        // A realtime insert can land while this page is in flight and would
        // then be in both — the id check keeps the list a set.
        final known = {for (final m in _messages) m.id};
        _messages.addAll(page.where((m) => !known.contains(m.id)));
        _hasMore = page.isNotEmpty;
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _errorMessage = AppLocalizations.of(
          context,
        )!.failedToLoadMessagesError,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickAttachments() async {
    final l10n = AppLocalizations.of(context)!;
    final remaining = _maxAttachments - _attachments.length;
    if (remaining <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.mediaLimitMessage)));
      return;
    }
    // Set before the picker rather than after, for the reason the composer
    // learned the hard way: the picker raises its own activity, and until it
    // returns nothing here has changed, so a second tap opened a second
    // picker and both batches were then trimmed against the same stale
    // `remaining`.
    setState(() => _isPicking = true);

    final MediaPickResult result;
    try {
      result = await pickMediaFiles(remaining: remaining);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isPicking = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.failedToAddMediaError)));
      return;
    }
    // The picker hands control to another activity, so this State can be gone
    // by the time it resolves.
    if (!mounted) return;
    setState(() {
      _attachments.addAll(result.items);
      _isPicking = false;
      // Same reasoning as [_onTyping]: the draft this token described no
      // longer matches what is about to be sent.
      _pendingSendToken = null;
    });
    if (mediaPickProblemMessage(result.firstProblem, l10n)
        case final message?) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _send() async {
    final l10n = AppLocalizations.of(context)!;
    final text = _textController.text.trim();
    // A photo with no caption is a message; an empty everything is not.
    if ((text.isEmpty && _attachments.isEmpty) || _isSending) return;

    setState(() {
      _isSending = true;
      _errorMessage = null;
    });
    // Minted once per draft and reused across retries — see
    // [_pendingSendToken]. Read before the request, not inside it: the field
    // itself is cleared on success, and [_onTyping] would otherwise treat
    // that as a new draft and null the token out from under this call.
    final clientToken = _pendingSendToken ??= const Uuid().v4();
    try {
      final message = await ref
          .read(roomsRepositoryProvider)
          .sendMessage(
            roomId: widget.roomId,
            authorId: ref.read(currentUserIdProvider)!,
            text: text,
            clientToken: clientToken,
            media: List.of(_attachments),
          );
      if (!mounted) return;
      // Clearing the field fires [_onTyping] anyway, which also nulls
      // [_pendingSendToken]; the timer is cancelled here so a pending one
      // can't re-announce after the message is gone.
      _typingTimer?.cancel();
      _textController.clear();
      setState(() {
        _attachments.clear();
        if (!_messages.any((m) => m.id == message.id)) {
          _messages.insert(0, message);
        }
      });
      ref.read(roomsRefreshTickProvider.notifier).bump();
    } catch (e) {
      if (!mounted) return;
      // The draft (and [_pendingSendToken]) deliberately survive a failure:
      // this is what lets a plain retap of send be answered by the unique
      // index instead of posting a second row.
      setState(() => _errorMessage = l10n.failedToSendMessageError);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _delete(RoomMessage message) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteMessageDialogTitle),
        content: Text(l10n.deleteMessageDialogContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await ref.read(roomsRepositoryProvider).deleteMessage(message.id);
      // The realtime UPDATE will bring the tombstone, but only if the socket
      // is up — repaint from here too rather than trusting it.
      if (!mounted) return;
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index != -1) {
        setState(
          () => _messages[index] = RoomMessage(
            id: message.id,
            roomId: message.roomId,
            authorId: message.authorId,
            text: '',
            createdAt: message.createdAt,
            authorName: message.authorName,
            deletedAt: DateTime.now(),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.failedToDeleteMessageError)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final room = ref.watch(roomProvider(widget.roomId));
    final viewerId = ref.watch(currentUserIdProvider);

    final status = _presenceLine(l10n, room, viewerId);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              room == null
                  ? l10n.roomChatTitle
                  : roomDisplayName(
                      room,
                      viewerId,
                      fallback: l10n.roomFallbackName,
                    ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // Under the name, where every messenger puts it — and only when
            // there is something to say: an empty second line would push the
            // name up for nothing.
            if (status != null)
              Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          // Who is in the room, its name and its picture — one level down
          // from the conversation, the way a messenger puts them.
          IconButton(
            icon: const Icon(Icons.group_outlined),
            tooltip: l10n.roomMembersTitle,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => RoomDetailsScreen(roomId: widget.roomId),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty && !_isLoading
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _errorMessage ?? l10n.noMessagesYetMessage,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: _messages.length + (_isLoading ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _messages.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final message = _messages[index];
                      return _MessageBubble(
                        message: message,
                        isMine: message.authorId == viewerId,
                        authorName:
                            room?.memberById(message.authorId)?.name ??
                            message.authorName ??
                            l10n.formerMemberLabel,
                        room: room,
                        receipts: _receipts,
                        onDelete:
                            message.authorId == viewerId && !message.isDeleted
                            ? () => _delete(message)
                            : null,
                      );
                    },
                  ),
          ),
          if (_errorMessage != null && _messages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_attachments.isNotEmpty)
            _AttachmentStrip(
              attachments: _attachments,
              onRemove: _isSending
                  ? null
                  : (item) => setState(() {
                      _attachments.remove(item);
                      _pendingSendToken = null;
                    }),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    tooltip: l10n.attachMediaTooltip,
                    onPressed: _isPicking || _isSending
                        ? null
                        : _pickAttachments,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      maxLines: 5,
                      minLines: 1,
                      maxLength: 5000,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: l10n.messageHint,
                        border: const OutlineInputBorder(),
                        // The counter only matters as one approaches the
                        // limit, and a chat field with a permanent "0/5000"
                        // under it looks like a form.
                        counterText: '',
                      ),
                    ),
                  ),
                  IconButton(
                    icon: _isSending
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    tooltip: l10n.sendMessageTooltip,
                    onPressed: _isSending ? null : _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isMine,
    required this.authorName,
    required this.room,
    required this.receipts,
    this.onDelete,
  });

  final RoomMessage message;
  final bool isMine;
  final String authorName;

  /// Null while the room list hasn't loaded this room yet — the status row
  /// just doesn't render, same as everywhere else this screen reads [room].
  final Room? room;

  /// Every member's read/delivered marks, keyed by user id. Only read when
  /// [isMine], since ticks are drawn on one's own sent messages, never on a
  /// message received from someone else.
  final Map<String, RoomMemberReceipt> receipts;

  final VoidCallback? onDelete;

  /// Ticks for [message], drawn only on the viewer's own, non-tombstoned
  /// messages — a direct room gets an icon (sent/delivered/read, the
  /// WhatsApp shape), a group room gets a "read N/total" count instead: a
  /// single icon cannot say "3 of 5 people have seen this", and the members
  /// screen already shows who these people are.
  Widget? _buildStatus(BuildContext context) {
    final currentRoom = room;
    if (!isMine || message.isDeleted || currentRoom == null) return null;

    final others = currentRoom.othersThan(message.authorId);
    final total = others.length;
    if (total == 0) return null;

    var read = 0;
    var delivered = 0;
    for (final other in others) {
      final receipt = receipts[other.userId];
      if (receipt == null) continue;
      if (!receipt.lastReadAt.isBefore(message.createdAt)) read++;
      if (!receipt.lastDeliveredAt.isBefore(message.createdAt)) delivered++;
    }

    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);

    if (currentRoom.isDirect) {
      if (read >= total) {
        return Semantics(
          label: l10n.roomMessageStatusReadLabel,
          child: Icon(Icons.done_all, size: 16, color: scheme.primary),
        );
      }
      if (delivered >= total) {
        return Semantics(
          label: l10n.roomMessageStatusDeliveredLabel,
          child: Icon(Icons.done_all, size: 16, color: scheme.onSurfaceVariant),
        );
      }
      return Semantics(
        label: l10n.roomMessageStatusSentLabel,
        child: Icon(Icons.check, size: 16, color: scheme.onSurfaceVariant),
      );
    }

    if (read > 0) {
      return Text(l10n.roomMessageReadCount(read, total), style: style);
    }
    if (delivered > 0) {
      return Text(
        l10n.roomMessageDeliveredCount(delivered, total),
        style: style,
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onDelete,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: BoxDecoration(
            color: isMine
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Own messages don't repeat one's own name: the side of the
              // screen already says who wrote them.
              if (!isMine)
                Text(
                  authorName,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.primary,
                  ),
                ),
              if (message.media.isNotEmpty)
                _MessageMedia(
                  // Per message, so a test can point at one bubble's
                  // attachments and two bubbles never share a key.
                  key: ValueKey('message-media-${message.id}'),
                  media: message.media,
                ),
              // A message can be attachments alone — an empty line under them
              // would only add height.
              if (message.isDeleted || message.text.isNotEmpty)
                Text(
                  message.isDeleted ? l10n.deletedMessageLabel : message.text,
                  style: message.isDeleted
                      ? theme.textTheme.bodyMedium?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: scheme.onSurfaceVariant,
                        )
                      : theme.textTheme.bodyMedium,
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    DateFormat.Hm().format(message.createdAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (_buildStatus(context) case final status?) ...[
                    const SizedBox(width: 4),
                    status,
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The picked-but-not-yet-sent files, above the input.
///
/// They are shown from the bytes already in hand (a video from its poster
/// frame), so nothing here waits on the network: the upload happens on send.
class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({required this.attachments, this.onRemove});

  final List<PickedMedia> attachments;

  /// Null while a send is in flight — those files are already going up, and
  /// removing one then would leave the message and the bucket disagreeing.
  final void Function(PickedMedia item)? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: 88,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = attachments[index];
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image(
                  image: sizedMemoryImage(
                    context,
                    item.previewBytes,
                    logicalWidth: 80,
                  ),
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                ),
              ),
              if (item.isVideo)
                const Positioned.fill(
                  child: Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              if (onRemove != null)
                Positioned(
                  top: -8,
                  right: -8,
                  child: IconButton(
                    icon: const Icon(Icons.cancel),
                    iconSize: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    tooltip: l10n.removeAttachmentTooltip,
                    onPressed: () => onRemove!(item),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A message's attachments inside its bubble: thumbnails, and a tap opens the
/// same fullscreen viewer the feed uses.
///
/// Always a thumbnail, never an inline player — a chat bubble is too small a
/// frame to play a clip in, and "tap opens it properly" is one rule for
/// photos and videos alike.
class _MessageMedia extends ConsumerStatefulWidget {
  const _MessageMedia({super.key, required this.media});

  final List<RoomMessageMedia> media;

  @override
  ConsumerState<_MessageMedia> createState() => _MessageMediaState();
}

class _MessageMediaState extends ConsumerState<_MessageMedia> {
  late List<RoomMessageMedia> _items = widget.media;
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  /// Signs everything this message carries in one round trip: ten is the
  /// most there can be, and a bubble shows them all at once anyway — the
  /// feed's window-of-one prefetch has nothing to save here.
  Future<void> _resolve() async {
    if (_resolving) return;
    final paths = pathsToSign(_items, [
      for (var i = 0; i < _items.length; i++) i,
    ]);
    if (paths.isEmpty) return;
    _resolving = true;
    try {
      final signed = await ref
          .read(roomsRepositoryProvider)
          .resolveMediaUrls(paths);
      if (!mounted) return;
      setState(() {
        _items = applySignedUrls(_items, [
          for (var i = 0; i < _items.length; i++) i,
        ], signed);
      });
    } catch (_) {
      // Offline, or the request timed out. The thumbnails stay on their
      // spinner; reopening the chat asks again, and there is nothing to say
      // here that the missing photo doesn't already say.
    } finally {
      _resolving = false;
    }
  }

  void _openFullscreen(int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => FullscreenMediaViewer(
          media: _items,
          initialIndex: index,
          resolve: ref.read(roomsRepositoryProvider).resolveMediaUrls,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // One attachment gets the room to be looked at; several become a grid of
    // squares, the way every chat shows an album.
    final side = _items.length == 1 ? 220.0 : 96.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var index = 0; index < _items.length; index++)
            GestureDetector(
              onTap: () => _openFullscreen(index),
              child: _Thumbnail(item: _items[index], side: side),
            ),
        ],
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.item, required this.side});

  final RoomMessageMedia item;
  final double side;

  @override
  Widget build(BuildContext context) {
    // A video shows its poster; an image shows itself. Either way one URL,
    // which is null until the batch above comes back.
    final url = item.isVideo ? item.posterUrl : item.url;
    return SizedBox(
      width: side,
      height: side,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url == null)
              const ColoredBox(
                color: Colors.black12,
                child: Center(child: CircularProgressIndicator()),
              )
            else
              CachedNetworkImage(
                imageUrl: url,
                // Keyed on the path, not the signed URL: the query string
                // changes on every signing and would cache-bust a photo that
                // has not changed at all.
                cacheKey: item.isVideo ? item.posterPath : item.storagePath,
                fit: BoxFit.cover,
              ),
            if (item.isVideo)
              const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  color: Colors.white,
                  size: 40,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
