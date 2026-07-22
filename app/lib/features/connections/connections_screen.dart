import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme_toggle_switch.dart';
import '../auth/auth_providers.dart';
import '../profile/profile_repository.dart';
import 'blocked_users_screen.dart';
import 'connection_duration.dart';
import 'connections_repository.dart';

final _friendsProvider = FutureProvider.autoDispose<List<Friend>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  return ref.watch(connectionsRepositoryProvider).fetchFriends(userId!);
});

class FriendAvatar extends ConsumerWidget {
  const FriendAvatar({super.key, required this.avatarPath});

  final String? avatarPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (avatarPath == null) {
      return const CircleAvatar(child: Icon(Icons.person));
    }

    final avatarAsync = ref.watch(avatarBytesProvider(avatarPath!));
    return CircleAvatar(
      backgroundImage: avatarAsync.value != null
          ? MemoryImage(avatarAsync.value!)
          : null,
      child: avatarAsync.value == null ? const Icon(Icons.person) : null,
    );
  }
}

class _FriendListItem extends ConsumerWidget {
  const _FriendListItem({required this.friend, required this.currentUserId});

  final Friend friend;
  final String currentUserId;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await action();
      ref.invalidate(_friendsProvider);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.unexpectedError)));
    }
  }

  Future<void> _confirmAndRun(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String content,
    required String confirmLabel,
    required Future<void> Function() action,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    await _run(context, ref, action);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final repo = ref.read(connectionsRepositoryProvider);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: FriendAvatar(avatarPath: friend.avatarPath),
      title: Text(friend.name),
      subtitle: Text(formatConnectionSummary(l10n, friend.connectedAt)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(friend.isMuted ? Icons.volume_off : Icons.volume_up),
            tooltip: friend.isMuted
                ? l10n.unmuteFriendTooltip
                : l10n.muteFriendTooltip,
            onPressed: () {
              if (friend.isMuted) {
                _run(
                  context,
                  ref,
                  () => repo.unmuteUser(
                    muterId: currentUserId,
                    mutedId: friend.userId,
                  ),
                );
              } else {
                _confirmAndRun(
                  context,
                  ref,
                  title: l10n.muteFriendTitle(friend.name),
                  content: l10n.muteFriendContent,
                  confirmLabel: l10n.muteButton,
                  action: () => repo.muteUser(
                    muterId: currentUserId,
                    mutedId: friend.userId,
                  ),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.block),
            color: friend.isBlocked
                ? Theme.of(context).colorScheme.error
                : null,
            tooltip: friend.isBlocked
                ? l10n.unblockButton
                : l10n.blockFriendTooltip,
            onPressed: () {
              if (friend.isBlocked) {
                _run(
                  context,
                  ref,
                  () => repo.unblockUser(
                    blockerId: currentUserId,
                    blockedId: friend.userId,
                  ),
                );
              } else {
                _confirmAndRun(
                  context,
                  ref,
                  title: l10n.blockFriendTitle(friend.name),
                  content: l10n.blockFriendContent,
                  confirmLabel: l10n.blockButton,
                  action: () => repo.blockUser(
                    blockerId: currentUserId,
                    blockedId: friend.userId,
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

class ConnectionsScreen extends ConsumerStatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  ConsumerState<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends ConsumerState<ConnectionsScreen> {
  final _codeController = TextEditingController();

  String? _myInviteCode;
  bool _isCreatingLink = false;
  String? _createLinkError;

  bool _isActivating = false;
  String? _activationMessage;
  bool _activationSucceeded = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _createInviteLink() async {
    setState(() {
      _isCreatingLink = true;
      _createLinkError = null;
    });
    try {
      final code = await ref
          .read(connectionsRepositoryProvider)
          .createInviteLink();
      if (!mounted) return;
      setState(() => _myInviteCode = code);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _createLinkError = AppLocalizations.of(context)!.unexpectedError,
      );
    } finally {
      if (mounted) setState(() => _isCreatingLink = false);
    }
  }

  Future<void> _activate() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      // Nothing to activate — tell the user plainly instead of firing a
      // request that comes back with a raw "Invite code not found".
      setState(() {
        _activationSucceeded = false;
        _activationMessage = AppLocalizations.of(
          context,
        )!.inviteCodeRequiredError;
      });
      return;
    }
    setState(() {
      _isActivating = true;
      _activationMessage = null;
    });
    try {
      final connection = await ref
          .read(connectionsRepositoryProvider)
          .activateInviteLink(code);
      if (!mounted) return;
      setState(() {
        _activationSucceeded = true;
        _activationMessage = AppLocalizations.of(
          context,
        )!.nowConnectedWithMessage(connection.ownerName);
      });
      ref.invalidate(_friendsProvider);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _activationSucceeded = false;
        _activationMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _activationSucceeded = false;
        _activationMessage = AppLocalizations.of(context)!.unexpectedError;
      });
    } finally {
      if (mounted) setState(() => _isActivating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final friendsAsync = ref.watch(_friendsProvider);
    final userId = ref.watch(currentUserIdProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.connectionsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.block),
            tooltip: l10n.blockedUsersTooltip,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BlockedUsersScreen()),
            ),
          ),
          const ThemeToggleSwitch(),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            l10n.inviteSectionTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (_myInviteCode != null)
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    _myInviteCode!,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: l10n.copyTooltip,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _myInviteCode!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.codeCopiedMessage)),
                    );
                  },
                ),
              ],
            ),
          const SizedBox(height: 8),
          if (_createLinkError != null) ...[
            Text(
              _createLinkError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          FilledButton(
            onPressed: _isCreatingLink ? null : _createInviteLink,
            child: _isCreatingLink
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _myInviteCode == null
                        ? l10n.createInviteCodeButton
                        : l10n.createNewCodeButton,
                  ),
          ),
          const SizedBox(height: 32),
          Text(
            l10n.haveCodeSectionTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _codeController,
            decoration: InputDecoration(labelText: l10n.inviteCodeLabel),
          ),
          const SizedBox(height: 12),
          if (_activationMessage != null) ...[
            Text(
              _activationMessage!,
              style: TextStyle(
                color: _activationSucceeded
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton(
            onPressed: _isActivating ? null : _activate,
            child: _isActivating
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.activateButton),
          ),
          const SizedBox(height: 32),
          Text(
            l10n.myConnectionsTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          friendsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stack) => Text(l10n.failedToLoadConnectionsError),
            data: (friends) => friends.isEmpty
                ? Text(l10n.noConnectionsYetMessage)
                : Column(
                    children: friends
                        .map(
                          (friend) => _FriendListItem(
                            friend: friend,
                            currentUserId: userId!,
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }
}
