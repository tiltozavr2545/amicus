import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/file_extension.dart';
import '../../shared/media_extensions.dart';
import '../../shared/picker_limit.dart';
import '../../shared/refresh_after_await.dart';
import '../../shared/write_ban.dart';
import '../auth/auth_providers.dart';
import '../settings/settings_button.dart';
import 'profile_page.dart';
import 'profile_photos_screen.dart';
import 'profile_repository.dart';

const _maxProfilePhotos = 80;

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
  bool _isAddingPhotos = false;

  /// Resolves upload errors after checking that the context is still mounted.
  void _showError(
    BuildContext context,
    String Function(AppLocalizations) message,
  ) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message(AppLocalizations.of(context)!))),
    );
  }

  Future<void> _editName(Profile profile) {
    final l10n = AppLocalizations.of(context)!;
    final repository = ref.read(profileRepositoryProvider);
    final container = refreshAfterAwait(context);
    var draft = profile.name;
    var saving = false;
    String? error;

    return showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> save() async {
            final name = draft.trim();
            if (saving || name == profile.name) return;
            if (name.isEmpty) {
              setDialogState(() => error = l10n.nameRequiredError);
              return;
            }

            setDialogState(() {
              saving = true;
              error = null;
            });
            try {
              await repository.updateName(userId: profile.id, name: name);
              container.invalidate(myProfileProvider);
            } catch (e) {
              if (!context.mounted) return;
              final bannedUntil = writeBanUntil(e);
              setDialogState(() {
                saving = false;
                error = bannedUntil == null
                    ? l10n.failedToSaveNameError
                    : l10n.writeRestrictedError(bannedUntil);
              });
              return;
            }
            if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
              Navigator.of(context).pop();
            }
          }

          return PopScope<void>(
            canPop: !saving,
            child: AlertDialog(
              scrollable: true,
              title: Text(l10n.editNameTitle),
              content: TextFormField(
                initialValue: profile.name,
                autofocus: true,
                enabled: !saving,
                textInputAction: TextInputAction.done,
                inputFormatters: [
                  FilteringTextInputFormatter.singleLineFormatter,
                ],
                maxLength: 100,
                decoration: InputDecoration(
                  labelText: l10n.nameLabel,
                  counterText: '',
                  errorText: error,
                  errorMaxLines: 4,
                ),
                onChanged: (value) => setDialogState(() {
                  draft = value;
                  error = null;
                }),
                onFieldSubmitted: (_) => save(),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.of(context).pop(),
                  child: Text(l10n.cancelButton),
                ),
                FilledButton(
                  onPressed: saving || draft.trim() == profile.name
                      ? null
                      : save,
                  child: saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.saveButton),
                ),
              ],
            ),
          );
        },
      ),
    );
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

    // Set BEFORE the picker — the same fix for the same reason as
    // `_pickMedia` in the composer: while the picker brings up its activity,
    // the "Add photo" button stays enabled (its `onPressed` looks at
    // `_isAddingPhotos` and `photos.length`, both of them pre-pick state), a
    // second tap opens a second picker, and both batches get trimmed by the
    // same `remaining`, computed before the first pick.
    setState(() => _isAddingPhotos = true);

    // Not `limit: remaining`: the picker rejects a limit below 2 outright,
    // which made the 80th photo unreachable. See [pickerLimit].
    final List<XFile> picked;
    try {
      picked = await ImagePicker().pickMultiImage(
        maxWidth: 1600,
        limit: pickerLimit(remaining),
      );
    } catch (_) {
      // Otherwise a throw from here would lock the button for good:
      // ProfileScreen lives as a StatefulShellRoute branch and is never
      // recreated. It would also be an unhandled async error — `_addPhotos`
      // is called as a `VoidCallback`.
      if (!mounted) return;
      setState(() => _isAddingPhotos = false);
      _showError(context, (l10n) => l10n.failedToAddPhotosError);
      return;
    }
    if (picked.isEmpty) {
      if (mounted) setState(() => _isAddingPhotos = false);
      return;
    }
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
      setState(() => _isAddingPhotos = false);
      _showError(context, (l10n) => l10n.unsupportedImageFormatError);
      return;
    }

    // Paths, not bytes: this used to call `await file.readAsBytes()` on every
    // file, and the whole batch — up to 80 photos at `maxWidth: 1600` — was
    // materialized in memory at once and held there for the entire
    // sequential upload. See [PendingPhoto]. As a bonus the list is no
    // longer async: there's nothing to read.
    final items = [
      for (final file in usable)
        PendingPhoto(
          photoClientToken: const Uuid().v4(),
          path: file.path,
          ext: fileExtension(file.name),
        ),
    ];
    // Captured before the await — see [refreshAfterAwait]. Without it, a
    // `finally` gated on `mounted` silently skipped the invalidation below
    // whenever the upload outlived this screen, leaving the gallery, the
    // 80-photo limit and both buttons' enabled state stuck on pre-upload
    // data until something unrelated happened to invalidate them.
    final container = refreshAfterAwait(context);
    try {
      await ref
          .read(profileRepositoryProvider)
          .addPhotos(userId: userId, items: items);
      if (usable.length < picked.take(remaining).length) {
        // ignore: use_build_context_synchronously
        _showError(context, (l10n) => l10n.unsupportedImageFormatError);
      }
    } catch (e) {
      // A write-ban refusal names itself and the date: "please try again"
      // here would invite repeating something that is certain to fail. The
      // outer catch deliberately doesn't get this change — what fails there
      // is file picking; the request hasn't reached the server yet.
      final bannedUntil = writeBanUntil(e);
      // The text is chosen before the call so the call itself stays on one
      // line: `// ignore` applies to the next line, and for a multi-line call
      // the analyzer points at the argument, which the suppression can't
      // reach.
      String message(AppLocalizations l10n) => bannedUntil != null
          ? l10n.writeRestrictedError(bannedUntil)
          : l10n.failedToAddPhotosError;
      // ignore: use_build_context_synchronously
      _showError(context, message);
    } finally {
      // Reloaded on error too, not just on success. `.timeout()` stops
      // waiting without cancelling the request, so the insert into
      // `profile_photos` could commit after this screen has already shown
      // "Failed to add photos". Without invalidating here,
      // `photosAsync.value` stays what it was BEFORE the attempt, and both
      // the 80-photo limit and the enabled state of both buttons hang off it
      // ("Reorder" at `length < 2`, "Delete" at `isEmpty`). ProfileScreen
      // lives as a StatefulShellRoute branch and isn't recreated when
      // switching tabs, so the autoDispose provider never dies and won't
      // reload itself.
      //
      // A stale list used to cost more: the `position` of new rows was
      // computed from it, so the next add aimed at occupied positions and
      // failed on `profile_photos_user_position_key` — permanently, until the
      // app was restarted. Positions are now assigned by the server
      // (`append_profile_photos()`, 20260824130000), so that dead end is
      // gone; reloading also picks up the new first photo as the avatar.
      //
      // Invalidation is unconditional, via `container` rather than `ref`:
      // `ref` dies with this screen, while the list that needs reloading must
      // outlive its exit (see [refreshAfterAwait]). `setState` touches this
      // screen's `context`, so it stays behind `mounted`.
      container.invalidate(myProfileProvider);
      container.invalidate(_profilePhotosProvider);
      if (mounted) setState(() => _isAddingPhotos = false);
    }
  }

  /// Opens a screen that may change the gallery, and reloads the gallery
  /// after returning.
  ///
  /// Unconditionally, not on `changed == true` as both call sites used to.
  /// `true` is returned only when the mutation made it ALL the way through:
  /// both [ProfilePhotoDeleteScreen] and [ProfilePhotoReorderScreen] show a
  /// snackbar on error and stay open, without calling `pop(true)`. But
  /// "error" and "nothing happened" are not the same thing: `.timeout()`
  /// stops waiting without cancelling the request, and photo deletion is
  /// additionally built as [deleteRowsThenObjects] — rows first, then
  /// objects — so the rows in `profile_photos` may already be gone.
  ///
  /// We then come back here with `null`, the list on the profile screen keeps
  /// rows that no longer exist, and that locks reordering for good:
  /// `reorder_profile_photos()` requires the WHOLE set, deleted ids drop out
  /// on the join inside, the lengths don't match — and the function answers
  /// `PT422` on every attempt. The profile screen lives as a
  /// StatefulShellRoute branch, so the autoDispose provider doesn't die when
  /// switching tabs and won't reload itself.
  ///
  /// The cost is one extra gallery query when the person opened the screen
  /// and left without changing anything.
  Future<void> _openGalleryEditor(Widget screen) async {
    // Captured before the await — see [refreshAfterAwait]. A `mounted` check
    // ahead of the `ref` calls used to gate the refresh itself: if this
    // screen's widget was torn down while `Navigator.push` awaited (seen on
    // iPad, apparently tied to window/scene reflows — Stage Manager, Split
    // View, rotation), the invalidation was silently skipped and the gallery
    // stayed stale until something else happened to invalidate it, which
    // read as "delete does nothing" until a later retry or tab switch.
    final container = refreshAfterAwait(context);
    await Navigator.of(
      context,
      rootNavigator: true,
    ).push<bool>(MaterialPageRoute(builder: (_) => screen));
    container.invalidate(myProfileProvider);
    container.invalidate(_profilePhotosProvider);
  }

  void _showPhotoActions(String userId) {
    final l10n = AppLocalizations.of(context)!;
    final photoState = ref.read(_profilePhotosProvider);
    final photos = photoState.value ?? const <ProfilePhoto>[];
    // Gallery mutations need a loaded snapshot to enforce the photo limit
    // and to know which photos can be reordered or deleted.
    final photosLoaded = photoState.hasValue;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text(
                  l10n.managePhotosTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              _PhotoMenuAction(
                icon: Icons.add_photo_alternate_outlined,
                label: l10n.addPhotoButton,
                onPressed: photosLoaded && photos.length < _maxProfilePhotos
                    ? () => _addPhotos(userId, photos)
                    : null,
              ),
              _PhotoMenuAction(
                icon: Icons.swap_vert,
                label: l10n.reorderPhotosButton,
                onPressed: photosLoaded && photos.length >= 2
                    ? () => _openGalleryEditor(
                        ProfilePhotoReorderScreen(photos: photos),
                      )
                    : null,
              ),
              _PhotoMenuAction(
                icon: Icons.delete_outline,
                label: l10n.deletePhotoButton,
                onPressed: photosLoaded && photos.isNotEmpty
                    ? () => _openGalleryEditor(
                        ProfilePhotoDeleteScreen(photos: photos),
                      )
                    : null,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profileState = ref.watch(myProfileProvider);
    final profile = profileState.value;
    final l10n = AppLocalizations.of(context)!;

    return ProfilePage(
      profile: profileState,
      photos: ref.watch(_profilePhotosProvider),
      secondaryAction: IconButton(
        tooltip: l10n.editNameTitle,
        icon: const Icon(Icons.edit_outlined),
        onPressed: profile == null ? null : () => _editName(profile),
      ),
      trailingAction: const SettingsButton(),
      photoAction: IconButton.filledTonal(
        tooltip: l10n.managePhotosTitle,
        iconSize: 18,
        icon: _isAddingPhotos
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.photo_camera_outlined),
        onPressed: profile == null || _isAddingPhotos
            ? null
            : () => _showPhotoActions(profile.id),
      ),
    );
  }
}

class _PhotoMenuAction extends StatelessWidget {
  const _PhotoMenuAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    enabled: onPressed != null,
    onTap: onPressed == null
        ? null
        : () {
            Navigator.of(context).pop();
            onPressed!();
          },
  );
}
