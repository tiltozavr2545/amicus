import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../auth/auth_providers.dart';
import '../feed/create_post_screen.dart';
import '../feed/feed_repository.dart';
import '../feed/post_list_view.dart';
import 'room_chat_screen.dart';
import 'room_details_screen.dart';
import 'rooms_repository.dart';

/// One room's feed: the posts addressed to this room, by every member.
///
/// Isolated in both directions — nobody outside the room can see these posts
/// (the RLS policy on `posts` decides that, not this screen), and they don't
/// leak into the main feed or onto the author's profile wall either.
class RoomFeedScreen extends ConsumerWidget {
  const RoomFeedScreen({super.key, required this.roomId});

  final String roomId;

  Future<void> _openComposer(BuildContext context, WidgetRef ref) async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(initialRoomId: roomId),
      ),
    );
    if (created == true) {
      // Same tick the bottom bar's composer bumps: this list keeps its state
      // while the composer is open, so nothing else would bring the new post
      // into it.
      ref.read(feedRefreshTickProvider.notifier).bump();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final room = ref.watch(roomProvider(roomId));
    final viewerId = ref.watch(currentUserIdProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          room == null
              ? l10n.roomFallbackName
              : roomDisplayName(
                  room,
                  viewerId,
                  fallback: l10n.roomFallbackName,
                ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // The room's other half, one tap away — the same pairing the room
          // list offers, so switching between them doesn't mean going back.
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            tooltip: l10n.openRoomChatTooltip,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => RoomChatScreen(roomId: roomId)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.group_outlined),
            tooltip: l10n.roomMembersTitle,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => RoomDetailsScreen(roomId: roomId),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: l10n.newPostTitle,
        onPressed: () => _openComposer(context, ref),
        child: const Icon(Icons.add),
      ),
      body: PostListView(
        roomId: roomId,
        emptyState: (context) =>
            Text(l10n.roomEmptyFeedMessage, textAlign: TextAlign.center),
      ),
    );
  }
}
