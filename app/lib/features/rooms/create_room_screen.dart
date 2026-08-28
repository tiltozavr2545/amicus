import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../connections/connections_repository.dart';
import '../connections/connections_screen.dart';
import 'room_chat_screen.dart';
import 'rooms_repository.dart';

/// Picks who a new room is for.
///
/// One person makes the two-person room — no name, no third member ever — and
/// that is why the name field only appears once a second person is ticked:
/// offering it for a pair would promise something the server refuses.
class CreateRoomScreen extends ConsumerStatefulWidget {
  const CreateRoomScreen({super.key});

  @override
  ConsumerState<CreateRoomScreen> createState() => _CreateRoomScreenState();
}

class _CreateRoomScreenState extends ConsumerState<CreateRoomScreen> {
  final _nameController = TextEditingController();
  final _selected = <String>{};

  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (_selected.isEmpty) {
      setState(() => _errorMessage = l10n.pickAtLeastOneMemberError);
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final roomId = await ref
          .read(roomsRepositoryProvider)
          .createRoom(
            memberIds: _selected.toList(),
            // A two-person room is named after the other person, so whatever
            // is in the field is not its name — don't send it.
            name: _selected.length == 1 ? null : _nameController.text.trim(),
          );
      ref.read(roomsRefreshTickProvider.notifier).bump();
      if (!mounted) return;
      // Straight into the new room's chat: the room was created to be used,
      // and coming back to a list to find it again is a wasted tap. Replacing
      // this route rather than stacking on it keeps Back going to the list.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => RoomChatScreen(roomId: roomId)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = l10n.failedToCreateRoomError);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final friendsAsync = ref.watch(friendsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.newRoomTitle),
        actions: [
          TextButton(
            onPressed: _isSubmitting ? null : _submit,
            child: _isSubmitting
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.createRoomButton),
          ),
        ],
      ),
      body: friendsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(child: Text(l10n.unexpectedError)),
        data: (friends) {
          // A blocked connection is filtered out here because the server
          // refuses to put the two of you in one room (the one thing a block
          // still does once you are both inside a room is nothing — see the
          // rooms migration).
          final candidates = [
            for (final friend in friends)
              if (!friend.isBlocked) friend,
          ];
          if (candidates.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                l10n.noConnectionsYetMessage,
                textAlign: TextAlign.center,
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(l10n.selectRoomMembersMessage),
              if (_selected.length > 1) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _nameController,
                  maxLength: 100,
                  decoration: InputDecoration(
                    labelText: l10n.roomNameLabel,
                    helperText: l10n.roomNameHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 8),
              for (final friend in candidates)
                CheckboxListTile(
                  value: _selected.contains(friend.userId),
                  secondary: FriendAvatar(avatarPath: friend.avatarPath),
                  title: Text(friend.name),
                  onChanged: _isSubmitting
                      ? null
                      : (value) => setState(() {
                          if (value ?? false) {
                            _selected.add(friend.userId);
                          } else {
                            _selected.remove(friend.userId);
                          }
                        }),
                ),
            ],
          );
        },
      ),
    );
  }
}
