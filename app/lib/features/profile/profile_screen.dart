import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/write_ban.dart';
import '../../shared/file_extension.dart';
import '../../shared/media_extensions.dart';
import '../../shared/picker_limit.dart';
import '../../shared/refresh_after_await.dart';
import '../../theme/theme_toggle_switch.dart';
import '../auth/auth_providers.dart';
import '../feed/post_list_view.dart';
import '../settings/settings_button.dart';
import 'profile_photos_screen.dart';
import 'profile_repository.dart';
import '../../shared/sized_memory_image.dart';

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
    // Captured before the await — see [refreshAfterAwait]. The name also
    // paints the shell's profile tab, which outlives this screen.
    final container = refreshAfterAwait(context);
    try {
      await ref
          .read(profileRepositoryProvider)
          .updateName(userId: userId, name: name);
      container.invalidate(myProfileProvider);
    } catch (e) {
      // The write ban now covers name changes too (20260924100000:
      // `update of name` on `users`), so AMB01 is now reachable from here.
      // Without this branch a banned user was shown "please try again" — an
      // invitation to repeat something that won't work until the ban ends.
      // Same reason and same shape as the other six places with
      // `writeBanUntil` (see `_addPhotos` below on line order and `ignore`).
      final bannedUntil = writeBanUntil(e);
      String message(AppLocalizations l10n) => bannedUntil != null
          ? l10n.writeRestrictedError(bannedUntil)
          : l10n.failedToSaveNameError;
      // _showError checks context.mounted itself before touching context —
      // the analyzer can't see across that call, only into this function.
      // ignore: use_build_context_synchronously
      _showError(context, message);
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
      // gone; the list still has to be reloaded so the person sees what
      // actually made it.
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
    ).push<bool>(MaterialPageRoute(builder: (_) => screen));
    container.invalidate(myProfileProvider);
    container.invalidate(_profilePhotosProvider);
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
    final profileAsync = ref.watch(myProfileProvider);
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
                                  : () => _openGalleryEditor(
                                      ProfilePhotoReorderScreen(photos: photos),
                                    ),
                            ),
                            _PhotoActionButton(
                              icon: Icons.delete_outline,
                              label: l10n.deletePhotoButton,
                              onPressed: !photosLoaded || photos.isEmpty
                                  ? null
                                  : () => _openGalleryEditor(
                                      ProfilePhotoDeleteScreen(photos: photos),
                                    ),
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
