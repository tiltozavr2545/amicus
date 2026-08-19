import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../feed/post_list_view.dart';
import '../profile/profile_photos_screen.dart';
import '../profile/profile_repository.dart';

final _friendPhotosProvider = FutureProvider.autoDispose
    .family<List<ProfilePhoto>, String>((ref, friendId) {
      return ref.watch(profileRepositoryProvider).fetchPhotos(friendId);
    });

/// Read-only view of a Connection's profile: their avatar, name, and their
/// posts — the same paginated list as the "My posts" section on the current
/// user's own profile, scoped to [friendId], with no editing controls.
///
/// Name and avatar path come from the already-loaded [Friend] the caller
/// tapped rather than a fresh fetch — the Connections list just loaded them,
/// so re-querying `users` here would be a redundant round trip. The photo
/// gallery itself is fetched here though, since the connections list never
/// loaded it — `profile_photos`' visibility (self or Connection, same as the
/// avatar) already allows this.
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

  void _openViewer(BuildContext context, List<ProfilePhoto> photos) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            ProfilePhotoViewerScreen(photos: photos, initialIndex: 0),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final avatarBytes = avatarPath == null
        ? null
        : ref.watch(avatarBytesProvider(avatarPath!)).value;
    final photos =
        ref.watch(_friendPhotosProvider(friendId)).value ??
        const <ProfilePhoto>[];

    final header = Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: GestureDetector(
              onTap: photos.isEmpty ? null : () => _openViewer(context, photos),
              child: CircleAvatar(
                radius: 72,
                backgroundImage: avatarBytes != null
                    ? MemoryImage(avatarBytes)
                    : null,
                child: avatarBytes == null
                    ? const Icon(Icons.person, size: 58)
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.postsTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(friendName)),
      body: PostListView(
        authorId: friendId,
        header: header,
        emptyState: (context) => Text(l10n.noAuthorPostsYetMessage),
      ),
    );
  }
}
