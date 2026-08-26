import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/file_extension.dart';
import '../auth/auth_providers.dart';
import '../connections/connections_repository.dart';
import '../connections/connections_screen.dart';
import 'room_avatar.dart';
import 'rooms_repository.dart';

/// Who is in the room, plus everything an owner can do to it: rename, add,
/// remove. Leaving is here for everyone.
///
/// Every button here is also a server-side rule (`create_room()` and friends
/// refuse what they must); hiding them is a courtesy to the finger, not the
/// enforcement.
class RoomDetailsScreen extends ConsumerStatefulWidget {
  const RoomDetailsScreen({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<RoomDetailsScreen> createState() => _RoomDetailsScreenState();
}

class _RoomDetailsScreenState extends ConsumerState<RoomDetailsScreen> {
  bool _isBusy = false;

  /// Runs one membership/name change, refreshes the list, and reports failure
  /// in place. Returns whether it worked, so callers that navigate afterwards
  /// (leaving the room) can tell.
  Future<bool> _run(
    Future<void> Function() action,
    String failureMessage,
  ) async {
    if (_isBusy) return false;
    setState(() => _isBusy = true);
    try {
      await action();
      ref.read(roomsRefreshTickProvider.notifier).bump();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failureMessage)));
      }
      return false;
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// Picks a picture for the room and uploads it. Owner-only and group-only —
  /// the server refuses both cases anyway, this only keeps the button away
  /// from fingers that would be told "no".
  ///
  /// `maxWidth: 1600` matches what the profile gallery picks at: the circle
  /// is small, but the same file is what a future full-size view would show,
  /// and shrinking it further here would be a decision that cannot be undone.
  Future<void> _pickAvatar(Room room) async {
    final l10n = AppLocalizations.of(context)!;
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.failedToUpdateRoomAvatarError)),
      );
      return;
    }
    if (picked == null || !mounted) return;

    await _run(
      () => ref
          .read(roomsRepositoryProvider)
          .setRoomAvatar(
            roomId: room.id,
            file: File(picked!.path),
            // One token per pick, not per attempt: a retry then addresses the
            // same object instead of leaving the first upload behind.
            token: const Uuid().v4(),
            ext: fileExtension(picked.name),
          ),
      l10n.failedToUpdateRoomAvatarError,
    );
  }

  Future<void> _rename(Room room) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: room.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.renameRoomTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: InputDecoration(
            labelText: l10n.roomNameLabel,
            helperText: l10n.roomNameHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(l10n.saveButton),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    // An empty field is not "no change" but "back to the members' names" —
    // that is the only way to undo a rename.
    await _run(
      () => ref
          .read(roomsRepositoryProvider)
          .renameRoom(roomId: room.id, name: name),
      l10n.failedToRenameRoomError,
    );
  }

  Future<void> _addMember(Room room) async {
    final l10n = AppLocalizations.of(context)!;
    final friends = await ref.read(friendsProvider.future);
    if (!mounted) return;

    final present = {for (final member in room.members) member.userId};
    final candidates = [
      for (final friend in friends)
        if (!present.contains(friend.userId) && !friend.isBlocked) friend,
    ];
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.noConnectionsToAddMessage)));
      return;
    }

    final userId = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final friend in candidates)
              ListTile(
                leading: FriendAvatar(avatarPath: friend.avatarPath),
                title: Text(friend.name),
                onTap: () => Navigator.of(context).pop(friend.userId),
              ),
          ],
        ),
      ),
    );
    if (userId == null || !mounted) return;

    await _run(
      () => ref
          .read(roomsRepositoryProvider)
          .addMember(roomId: room.id, userId: userId),
      l10n.failedToUpdateRoomMembersError,
    );
  }

  Future<void> _removeMember(Room room, RoomMember member) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.removeMemberDialogTitle(member.name)),
        content: Text(l10n.removeMemberDialogContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.removeMemberTooltip),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _run(
      () => ref
          .read(roomsRepositoryProvider)
          .removeMember(roomId: room.id, userId: member.userId),
      l10n.failedToUpdateRoomMembersError,
    );
  }

  Future<void> _leave(Room room) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.leaveRoomDialogTitle),
        // The two-person room is the pair itself, so one side leaving ends it
        // for both — that has to be said before the tap, not after.
        content: Text(
          room.isDirect
              ? l10n.leaveDirectRoomDialogContent
              : l10n.leaveRoomDialogContent,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.leaveRoomButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final left = await _run(
      () => ref.read(roomsRepositoryProvider).leaveRoom(room.id),
      l10n.failedToLeaveRoomError,
    );
    // Back to whatever opened this screen: the room is no longer in the list,
    // and this route (and the room's feed underneath it, when that is where we
    // came from) has nothing left to show.
    if (left && mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final room = ref.watch(roomProvider(widget.roomId));
    final viewerId = ref.watch(currentUserIdProvider);

    if (room == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.roomFallbackName)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // A two-person room has an owner in the database — it is simply the
    // member with the lowest `seq`, and the schema has no case without one —
    // but the idea means nothing there: nobody can be added, removed, or
    // renamed out of it, and either side leaving ends it for both. So the
    // whole notion stays off screen rather than appearing next to one of the
    // two names for no reason.
    final showsOwnership = !room.isDirect;
    final canManage = room.isOwnedBy(viewerId) && showsOwnership;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          roomDisplayName(room, viewerId, fallback: l10n.roomFallbackName),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (canManage)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: l10n.renameRoomTitle,
              onPressed: _isBusy ? null : () => _rename(room),
            ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                RoomAvatar(room: room, viewerId: viewerId, radius: 44),
                if (canManage) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.photo_outlined),
                        label: Text(l10n.changeRoomAvatarButton),
                        onPressed: _isBusy ? null : () => _pickAvatar(room),
                      ),
                      if (room.avatarPath != null)
                        TextButton(
                          onPressed: _isBusy
                              ? null
                              : () => _run(
                                  () => ref
                                      .read(roomsRepositoryProvider)
                                      .clearRoomAvatar(room.id),
                                  l10n.failedToUpdateRoomAvatarError,
                                ),
                          child: Text(l10n.removeRoomAvatarButton),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          ListTile(
            title: Text(
              l10n.roomMembersTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            subtitle: Text(l10n.roomMembersCount(room.members.length)),
          ),
          for (final member in room.members)
            ListTile(
              leading: FriendAvatar(avatarPath: member.avatarPath),
              title: Text(member.name),
              subtitle: showsOwnership && member.userId == room.ownerId
                  ? Text(l10n.roomOwnerLabel)
                  : null,
              trailing: canManage && member.userId != viewerId
                  ? IconButton(
                      icon: const Icon(Icons.person_remove_outlined),
                      tooltip: l10n.removeMemberTooltip,
                      onPressed: _isBusy
                          ? null
                          : () => _removeMember(room, member),
                    )
                  : null,
            ),
          if (canManage)
            ListTile(
              leading: const Icon(Icons.person_add_outlined),
              title: Text(l10n.addMemberButton),
              onTap: _isBusy ? null : () => _addMember(room),
            ),
          const Divider(),
          ListTile(
            leading: Icon(
              Icons.logout,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              l10n.leaveRoomButton,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: _isBusy ? null : () => _leave(room),
          ),
        ],
      ),
    );
  }
}
