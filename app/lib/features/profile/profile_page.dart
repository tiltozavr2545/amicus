import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/content_width.dart';
import '../../shared/photo_viewer_route.dart';
import '../../shared/sized_memory_image.dart';
import '../feed/post_list_view.dart';
import 'profile_photos_screen.dart';
import 'profile_repository.dart';

/// Shared layout for the signed-in user's profile and profiles opened as routes.
class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    required this.profile,
    required this.photos,
    required this.trailingAction,
    this.secondaryAction,
    this.photoAction,
  });

  final AsyncValue<Profile> profile;
  final AsyncValue<List<ProfilePhoto>> photos;
  final Widget trailingAction;
  final Widget? secondaryAction;
  final Widget? photoAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showsBack = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;

    return Scaffold(
      appBar: AppBar(
        // Keep the same title constraints with or without route actions.
        leading: showsBack ? null : const SizedBox.shrink(),
        centerTitle: true,
        titleSpacing: 0,
        title: Text(
          l10n.profileTitle,
          style: Theme.of(context).textTheme.titleLarge,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          SizedBox.square(dimension: 48, child: secondaryAction),
          SizedBox.square(dimension: 48, child: trailingAction),
        ],
      ),
      body: ContentWidth(
        child: profile.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) =>
              Center(child: Text(l10n.failedToLoadProfileError)),
          data: (profile) => PostListView(
            authorId: profile.id,
            header: _ProfileHeader(
              profile: profile,
              photoState: photos,
              photoAction: photoAction,
            ),
            emptyState: (context) => Text(l10n.noProfilePostsYetMessage),
          ),
        ),
      ),
    );
  }
}

class _ProfileHeader extends ConsumerWidget {
  const _ProfileHeader({
    required this.profile,
    required this.photoState,
    this.photoAction,
  });

  final Profile profile;
  final AsyncValue<List<ProfilePhoto>> photoState;
  final Widget? photoAction;

  void _openViewer(BuildContext context, List<ProfilePhoto> photos) {
    Navigator.of(context, rootNavigator: true).push(
      photoViewerRoute(
        (_) => ProfilePhotoViewerScreen(photos: photos, initialIndex: 0),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final avatarPath = profile.avatarPath;
    final avatarBytes = avatarPath == null
        ? null
        : ref.watch(avatarBytesProvider(avatarPath)).value;
    final photos = photoState.value ?? const <ProfilePhoto>[];

    final portrait = SizedBox.square(
      dimension: 88,
      child: Stack(
        children: [
          GestureDetector(
            onTap: photos.isEmpty ? null : () => _openViewer(context, photos),
            child: CircleAvatar(
              backgroundColor: theme.colorScheme.surfaceContainerHigh,
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              radius: 40,
              backgroundImage: avatarBytes == null
                  ? null
                  : sizedMemoryImage(context, avatarBytes, logicalWidth: 80),
              child: avatarBytes == null
                  ? const Icon(Icons.person, size: 34)
                  : null,
            ),
          ),
          if (photoAction != null)
            PositionedDirectional(end: 0, bottom: 0, child: photoAction!),
        ],
      ),
    );
    final name = Text(profile.name, style: theme.textTheme.headlineMedium);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth < 340
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [portrait, const SizedBox(height: 12), name],
                  )
                : Row(
                    children: [
                      portrait,
                      const SizedBox(width: 20),
                      Expanded(child: name),
                    ],
                  ),
          ),
          if (photoState.hasError) ...[
            const SizedBox(height: 12),
            Text(
              l10n.failedToLoadPhotosError,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(l10n.postsTitle, style: theme.textTheme.titleLarge),
        ],
      ),
    );
  }
}
