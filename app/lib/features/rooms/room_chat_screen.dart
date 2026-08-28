import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../auth/auth_providers.dart';
import 'room_details_screen.dart';
import 'rooms_repository.dart';

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
  String? _errorMessage;

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

  Future<void> _send() async {
    final l10n = AppLocalizations.of(context)!;
    final text = _textController.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() {
      _isSending = true;
      _errorMessage = null;
    });
    try {
      final message = await ref
          .read(roomsRepositoryProvider)
          .sendMessage(
            roomId: widget.roomId,
            authorId: ref.read(currentUserIdProvider)!,
            text: text,
            // One token per send, minted here: a retry after a timeout that
            // committed anyway lands on the same unique index instead of
            // saying the same thing twice.
            clientToken: const Uuid().v4(),
          );
      if (!mounted) return;
      _textController.clear();
      setState(() {
        if (!_messages.any((m) => m.id == message.id)) {
          _messages.insert(0, message);
        }
      });
      ref.read(roomsRefreshTickProvider.notifier).bump();
    } catch (e) {
      if (!mounted) return;
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

    return Scaffold(
      appBar: AppBar(
        title: Text(
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
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
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
