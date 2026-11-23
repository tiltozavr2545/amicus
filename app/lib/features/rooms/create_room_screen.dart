import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/bottom_navigation_inset.dart';
import '../../shared/content_width.dart';
import '../../shared/refresh_after_await.dart';
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
  String? _creationToken;

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
    // Captured before the await — see [refreshAfterAwait]. The rooms tab that
    // has to show the new room is a different screen from this one.
    final container = refreshAfterAwait(context);
    try {
      final roomId = await ref
          .read(roomsRepositoryProvider)
          .createRoom(
            memberIds: _selected.toList(),
            clientToken: _selected.length > 1
                ? (_creationToken ??= const Uuid().v4())
                : null,
            // A two-person room is named after the other person, so whatever
            // is in the field is not its name — don't send it.
            name: _selected.length == 1 ? null : _nameController.text.trim(),
          );
      container.read(roomsRefreshTickProvider.notifier).bump();
      if (!mounted) return;
      // Close creation, then cover the shell with the chat. Back returns to
      // the room list, and the bottom navigation never enters the conversation.
      final local = Navigator.of(context);
      final root = Navigator.of(context, rootNavigator: true);
      final chat = MaterialPageRoute<void>(
        builder: (_) => RoomChatScreen(roomId: roomId),
      );
      if (identical(local, root)) {
        unawaited(root.pushReplacement(chat));
      } else {
        local.pop();
        unawaited(root.push(chat));
      }
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
      body: ContentWidth(
        child: friendsAsync.when(
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
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + BottomNavigationInset.of(context),
              ),
              children: [
                Text(l10n.selectRoomMembersMessage),
                if (_selected.length > 1) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _nameController,
                    readOnly: _isSubmitting,
                    onChanged: (_) => _creationToken = null,
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
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
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
                            _creationToken = null;
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
      ),
    );
  }
}
