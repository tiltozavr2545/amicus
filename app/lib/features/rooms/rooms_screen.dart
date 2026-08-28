import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme_toggle_switch.dart';
import '../auth/auth_providers.dart';
import '../connections/friend_profile_screen.dart';
import '../settings/settings_button.dart';
import 'create_room_screen.dart';
import 'room_avatar.dart';
import 'room_chat_screen.dart';
import 'room_details_screen.dart';
import 'rooms_repository.dart';

/// The rooms tab: every room the viewer is in, the most recently talked-in
/// first.
///
/// A room is its chat, so a row opens the chat — the way a row in any list of
/// conversations does. Who is in the room, its name and its picture live one
/// level down, behind the room's own picture here and behind the members
/// button in the chat's app bar.
class RoomsScreen extends ConsumerWidget {
  const RoomsScreen({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    ref.read(roomsRefreshTickProvider.notifier).bump();
    await ref.read(myRoomsProvider.future);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final roomsAsync = ref.watch(myRoomsProvider);
    final viewerId = ref.watch(currentUserIdProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.roomsTitle),
        actions: const [ThemeToggleSwitch(), SettingsButton()],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: l10n.newRoomTitle,
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const CreateRoomScreen())),
        child: const Icon(Icons.group_add_outlined),
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: switch (roomsAsync) {
          // Every branch is scrollable on purpose: RefreshIndicator only
          // arms itself over a scrollable, and "pull to try again" has to
          // work on the error and empty states too — those are exactly the
          // moments someone reaches for it.
          AsyncValue(hasError: true) => _CenteredMessage(
            child: Text(l10n.failedToLoadRoomsError),
          ),
          AsyncValue(:final value?) when value.isEmpty => _CenteredMessage(
            child: Text(l10n.noRoomsYetMessage, textAlign: TextAlign.center),
          ),
          AsyncValue(:final value?) => ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: value.length,
            itemBuilder: (context, index) =>
                _RoomListItem(room: value[index], viewerId: viewerId),
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
    children: [child],
  );
}

class _RoomListItem extends StatelessWidget {
  const _RoomListItem({required this.room, required this.viewerId});

  final Room room;
  final String? viewerId;

  /// What the row says under the room's name: the last thing said in the
  /// chat, or — while nobody has said anything — how many people are in it.
  /// A two-person room says neither: "2 участника" about a pair is noise.
  ///
  /// A message that is only a photo has no text to preview, and a blank line
  /// under the name reads as an empty room; it says "Photo" instead — on the
  /// reader's own language, which is why the server sends one bit rather than
  /// a ready-made line.
  String? _subtitle(AppLocalizations l10n) {
    final text = room.lastMessageText;
    final preview = (text == null || text.isEmpty)
        ? (room.lastMessageHasMedia ? l10n.mediaMessagePreview : null)
        : text;
    if (preview != null) {
      final author = room.memberById(room.lastMessageAuthorId);
      return author == null ? preview : '${author.name}: $preview';
    }
    return room.isDirect ? null : l10n.roomMembersCount(room.members.length);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final subtitle = _subtitle(l10n);

    return ListTile(
      // Tapping the circle opens whatever it depicts, and only the
      // two-person room depicts a person — see [RoomAvatar]. Everything else
      // is the room, so it goes to the room's details.
      leading: GestureDetector(
        onTap: () {
          final person = RoomAvatar.personBehind(room, viewerId);
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => person == null
                  ? RoomDetailsScreen(roomId: room.id)
                  : FriendProfileScreen(
                      friendId: person.userId,
                      friendName: person.name,
                      avatarPath: person.avatarPath,
                    ),
            ),
          );
        },
        child: RoomAvatar(room: room, viewerId: viewerId),
      ),
      title: Text(
        roomDisplayName(room, viewerId, fallback: l10n.roomFallbackName),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => RoomChatScreen(roomId: room.id)),
      ),
      // Marks, not buttons: the whole row already opens the chat, and a
      // second tap target that does the same thing only makes the row harder
      // to hit. A muted room still shows its unread count — mute is about
      // pushes, and the badge is the one thing that says what was missed.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (room.notificationsMuted)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(
                Icons.notifications_off_outlined,
                size: 18,
                semanticLabel: l10n.roomMutedLabel,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          if (room.unreadCount > 0) Badge.count(count: room.unreadCount),
        ],
      ),
    );
  }
}
