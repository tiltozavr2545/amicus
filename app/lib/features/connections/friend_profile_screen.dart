import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../feed/post_list_view.dart';
import '../profile/profile_repository.dart';

/// Read-only view of a Connection's profile: their avatar, name, and their
/// posts — the same paginated list as the "My posts" section on the current
/// user's own profile, scoped to [friendId], with no editing controls.
///
/// Name and avatar path come from the already-loaded [Friend] the caller
/// tapped rather than a fresh fetch — the Connections list just loaded them,
/// so re-querying `users` here would be a redundant round trip.
class FriendProfileScreen extends ConsumerWidget {
  const FriendProfileScreen({
    super.key,
    required this.friendId,
    required this.friendName,
    this.avatarPath,
  });

  final String friendId;
  final String friendName;
  final String? avatarPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final avatarBytes = avatarPath == null
        ? null
        : ref.watch(avatarBytesProvider(avatarPath!)).value;

    return Scaffold(
      appBar: AppBar(title: Text(friendName)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            child: CircleAvatar(
              radius: 48,
              backgroundImage: avatarBytes != null
                  ? MemoryImage(avatarBytes)
                  : null,
              child: avatarBytes == null
                  ? const Icon(Icons.person, size: 32)
                  : null,
            ),
          ),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.postsTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          Expanded(
            child: PostListView(
              authorId: friendId,
              emptyState: (context) => Text(l10n.noAuthorPostsYetMessage),
            ),
          ),
        ],
      ),
    );
  }
}
