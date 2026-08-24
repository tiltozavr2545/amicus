import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/file_extension.dart';
import '../../shared/media_extensions.dart';
import '../../shared/picker_limit.dart';
import '../../theme/theme_toggle_switch.dart';
import '../auth/auth_providers.dart';
import '../feed/post_list_view.dart';
import '../settings/settings_button.dart';
import 'profile_photos_screen.dart';
import 'profile_repository.dart';
import '../../shared/sized_memory_image.dart';

const _maxProfilePhotos = 80;

final _profileProvider = FutureProvider.autoDispose<Profile>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  return ref.watch(profileRepositoryProvider).fetchProfile(userId!);
});

final _profilePhotosProvider = FutureProvider.autoDispose<List<ProfilePhoto>>((
  ref,
) {
  final userId = ref.watch(currentUserIdProvider);
  return ref.watch(profileRepositoryProvider).fetchPhotos(userId!);
});

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _nameController = TextEditingController();
  bool _isSaving = false;
  bool _isAddingPhotos = false;
  bool _nameSeeded = false;

  @override
  void initState() {
    super.initState();
    // Repaints the Save button's visibility (shown only once the field
    // differs from the loaded profile) as the user types.
    _nameController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// Shared error feedback for every write path on this screen. Takes a
  /// message *builder*, not a resolved string: after an `await`, the
  /// `AppLocalizations.of(context)` lookup itself is only safe once
  /// `context.mounted` has been checked, so it has to happen in here too —
  /// resolving the string at the call site (before this runs) would read
  /// context that may already be gone.
  void _showError(
    BuildContext context,
    String Function(AppLocalizations) message,
  ) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message(AppLocalizations.of(context)!))),
    );
  }

  Future<void> _saveName(String userId) async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showError(context, (l10n) => l10n.nameRequiredError);
      return;
    }
    setState(() => _isSaving = true);
    try {
      await ref
          .read(profileRepositoryProvider)
          .updateName(userId: userId, name: name);
      ref.invalidate(_profileProvider);
    } catch (e) {
      // _showError checks context.mounted itself before touching context —
      // the analyzer can't see across that call, only into this function.
      // ignore: use_build_context_synchronously
      _showError(context, (l10n) => l10n.failedToSaveNameError);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _addPhotos(String userId, List<ProfilePhoto> existing) async {
    final l10n = AppLocalizations.of(context)!;
    final remaining = _maxProfilePhotos - existing.length;
    if (remaining <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.photoLimitMessage)));
      return;
    }

    // Not `limit: remaining`: the picker rejects a limit below 2 outright,
    // which made the 80th photo unreachable. See [pickerLimit].
    final picked = await ImagePicker().pickMultiImage(
      maxWidth: 1600,
      limit: pickerLimit(remaining),
    );
    if (picked.isEmpty) return;
    // The picker runs in its own activity, so this State can be gone by the
    // time it resolves — the same guard every other `await` here already has.
    if (!mounted) return;

    // The bucket takes an object's content type from the extension in its
    // name, so a format it doesn't accept fails on upload and fails again on
    // every retry. Rejected here, with a reason, rather than as a bare
    // "failed to add photos" — see [imageExtensions].
    final usable = [
      for (final file in picked.take(remaining))
        if (imageExtensions.contains(fileExtension(file.name))) file,
    ];
    if (usable.isEmpty) {
      _showError(context, (l10n) => l10n.unsupportedImageFormatError);
      return;
    }

    setState(() => _isAddingPhotos = true);
    try {
      final items = [
        for (final file in usable)
          PendingPhoto(
            photoClientToken: const Uuid().v4(),
            bytes: await file.readAsBytes(),
            ext: fileExtension(file.name),
          ),
      ];
      await ref
          .read(profileRepositoryProvider)
          .addPhotos(userId: userId, items: items, existing: existing);
      ref.invalidate(_profileProvider);
      ref.invalidate(_profilePhotosProvider);
      if (usable.length < picked.take(remaining).length) {
        // ignore: use_build_context_synchronously
        _showError(context, (l10n) => l10n.unsupportedImageFormatError);
      }
    } catch (e) {
      // ignore: use_build_context_synchronously
      _showError(context, (l10n) => l10n.failedToAddPhotosError);
    } finally {
      if (mounted) setState(() => _isAddingPhotos = false);
    }
  }

  Future<void> _openReorder(List<ProfilePhoto> photos) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProfilePhotoReorderScreen(photos: photos),
      ),
    );
    if (changed == true) {
      ref.invalidate(_profileProvider);
      ref.invalidate(_profilePhotosProvider);
    }
  }

  Future<void> _openDelete(List<ProfilePhoto> photos) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProfilePhotoDeleteScreen(photos: photos),
      ),
    );
    if (changed == true) {
      ref.invalidate(_profileProvider);
      ref.invalidate(_profilePhotosProvider);
    }
  }

  void _openViewer(List<ProfilePhoto> photos) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            ProfilePhotoViewerScreen(photos: photos, initialIndex: 0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userId = ref.watch(currentUserIdProvider);
    final profileAsync = ref.watch(_profileProvider);
    final photosAsync = ref.watch(_profilePhotosProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.profileTitle),
        actions: [const ThemeToggleSwitch(), const SettingsButton()],
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) =>
            Center(child: Text(l10n.failedToLoadProfileError)),
        data: (profile) {
          // Seeded once, tracked by a flag rather than by the field being
          // empty. The listener registered in initState rebuilds on every
          // keystroke, so an emptiness test ran again the instant the user
          // cleared the field — and put the old name straight back, caret and
          // all. Selecting all and pressing backspace to retype a name was
          // therefore impossible; the field could only be edited around its
          // existing text. Same seed-once shape SettingsScreen uses for
          // `_prefs`.
          if (!_nameSeeded) {
            _nameSeeded = true;
            _nameController.text = profile.name;
          }
          final avatarBytes = profile.avatarPath == null
              ? null
              : ref.watch(avatarBytesProvider(profile.avatarPath!)).value;
          // Buttons that mutate the gallery need the *current* list (to
          // compute next positions, or to know what's selectable) — holding
          // them off until the list has actually loaded avoids an add/reorder
          // racing ahead of a fetch still in flight and computing positions
          // against a stale (empty) view of the gallery.
          final photosLoaded = photosAsync.hasValue;
          final photos = photosAsync.value ?? const <ProfilePhoto>[];
          final nameChanged = _nameController.text.trim() != profile.name;

          final header = Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Each half of the row is exactly W/2 wide, so centering
                    // a child within its half puts that child's own center at
                    // exactly a quarter of the *whole* row's width from that
                    // half's outer edge — W/4 from the left for the avatar,
                    // W/4 from the right for the buttons — regardless of
                    // either child's actual size.
                    Expanded(
                      child: Center(
                        child: GestureDetector(
                          onTap: photos.isEmpty
                              ? null
                              : () => _openViewer(photos),
                          child: CircleAvatar(
                            radius: 72,
                            backgroundImage: avatarBytes != null
                                ? sizedMemoryImage(
                                    context,
                                    avatarBytes,
                                    logicalWidth: 144,
                                  )
                                : null,
                            child: avatarBytes == null
                                ? const Icon(Icons.person, size: 58)
                                : null,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _PhotoActionButton(
                              icon: Icons.add_photo_alternate_outlined,
                              label: l10n.addPhotoButton,
                              loading: _isAddingPhotos,
                              onPressed:
                                  !photosLoaded ||
                                      _isAddingPhotos ||
                                      photos.length >= _maxProfilePhotos
                                  ? null
                                  : () => _addPhotos(userId!, photos),
                            ),
                            _PhotoActionButton(
                              icon: Icons.swap_vert,
                              label: l10n.reorderPhotosButton,
                              onPressed: !photosLoaded || photos.length < 2
                                  ? null
                                  : () => _openReorder(photos),
                            ),
                            _PhotoActionButton(
                              icon: Icons.delete_outline,
                              label: l10n.deletePhotoButton,
                              onPressed: !photosLoaded || photos.isEmpty
                                  ? null
                                  : () => _openDelete(photos),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                // A failed gallery load is otherwise indistinguishable from
                // having no photos: the three buttons above just sit disabled
                // (they key off `photosLoaded`, which is false on error too)
                // and the avatar falls back to the person icon. The string for
                // this existed in both locales from the start and was never
                // wired to anything — the audit found it as an unused ARB key,
                // which is what led back here.
                if (photosAsync.hasError) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.failedToLoadPhotosError,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                TextField(
                  controller: _nameController,
                  // Matches the `users_name_length` CHECK added in
                  // 20260820140000, so the cap reads as a full field rather
                  // than as a database error on save. No counter: unlike the
                  // composer's 5000, nobody writes a name near this limit.
                  maxLength: 100,
                  buildCounter:
                      (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                  decoration: InputDecoration(labelText: l10n.nameLabel),
                ),
                if (nameChanged) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _isSaving ? null : () => _saveName(userId!),
                    child: _isSaving
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.saveButton),
                  ),
                ],
                const SizedBox(height: 24),
                const Divider(height: 1),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.myPostsTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          );

          return PostListView(
            authorId: userId,
            header: header,
            emptyState: (context) => Text(l10n.noOwnPostsYetMessage),
          );
        },
      ),
    );
  }
}

class _PhotoActionButton extends StatelessWidget {
  const _PhotoActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        textStyle: const TextStyle(fontSize: 16),
      ),
      icon: loading
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 24),
      label: Text(label),
    );
  }
}
