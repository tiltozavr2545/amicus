import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../auth/auth_providers.dart';
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
  bool _isLoading = false;
  bool _hasMore = true;
  bool _isSending = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadMore();
    _subscribe();
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
    this.onDelete,
  });

  final RoomMessage message;
  final bool isMine;
  final String authorName;
  final VoidCallback? onDelete;

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
              Text(
                DateFormat.Hm().format(message.createdAt),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
