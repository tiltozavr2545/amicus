import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../auth/auth_providers.dart';
import 'connections_repository.dart';
import 'connections_screen.dart';

final _blockedUsersProvider = FutureProvider.autoDispose<List<BlockedUser>>((
  ref,
) {
  final userId = ref.watch(currentUserIdProvider);
  return ref.watch(connectionsRepositoryProvider).fetchBlockedUsers(userId!);
});

class _BlockedUserListItem extends ConsumerWidget {
  const _BlockedUserListItem({
    required this.blockedUser,
    required this.currentUserId,
  });

  final BlockedUser blockedUser;
  final String currentUserId;

  Future<void> _unblock(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await ref
          .read(connectionsRepositoryProvider)
          .unblockUser(blockerId: currentUserId, blockedId: blockedUser.userId);
      ref.invalidate(_blockedUsersProvider);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.unexpectedError)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return ListTile(
      leading: FriendAvatar(avatarPath: blockedUser.avatarPath),
      title: Text(blockedUser.name),
      trailing: TextButton(
        onPressed: () => _unblock(context, ref),
        child: Text(l10n.unblockButton),
      ),
    );
  }
}

class BlockedUsersScreen extends ConsumerWidget {
  const BlockedUsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blockedAsync = ref.watch(_blockedUsersProvider);
    final userId = ref.watch(currentUserIdProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.blockedUsersTitle)),
      body: blockedAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) =>
            Center(child: Text(l10n.failedToLoadConnectionsError)),
        data: (blockedUsers) => blockedUsers.isEmpty
            ? Center(child: Text(l10n.noBlockedUsersMessage))
            : ListView(
                children: blockedUsers
                    .map(
                      (blockedUser) => _BlockedUserListItem(
                        blockedUser: blockedUser,
                        currentUserId: userId!,
                      ),
                    )
                    .toList(),
              ),
      ),
    );
  }
}
