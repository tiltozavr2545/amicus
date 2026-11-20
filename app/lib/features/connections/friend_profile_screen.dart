import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../moderation/report_repository.dart';
import '../moderation/report_sheet.dart';
import '../profile/profile_page.dart';
import '../profile/profile_repository.dart';

final _friendPhotosProvider = FutureProvider.autoDispose
    .family<List<ProfilePhoto>, String>((ref, friendId) {
      return ref.watch(profileRepositoryProvider).fetchPhotos(friendId);
    });

/// Shows a Connection's profile with the name and avatar supplied by the
/// caller. Only the gallery and posts need to be fetched here.
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

    return ProfilePage(
      profile: AsyncData(
        Profile(id: friendId, name: friendName, avatarPath: avatarPath),
      ),
      photos: ref.watch(_friendPhotosProvider(friendId)),
      trailingAction: PopupMenuButton<void>(
        itemBuilder: (context) => [
          PopupMenuItem(
            onTap: () => showReportSheet(
              context,
              kind: ReportTargetKind.user,
              targetId: friendId,
            ),
            child: Text(l10n.reportButton),
          ),
        ],
      ),
    );
  }
}
