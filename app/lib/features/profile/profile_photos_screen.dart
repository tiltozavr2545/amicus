import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reorderables/reorderables.dart';

import '../../l10n/app_localizations.dart';
import 'profile_repository.dart';
import '../../shared/sized_memory_image.dart';

const _thumbSize = 140.0;

/// Full-screen, swipeable view of a user's profile photo gallery — opened by
/// tapping the avatar on [ProfileScreen]. Reuses [avatarBytesProvider] (keyed
/// by storage path) rather than resolving a signed URL, same as the small
/// avatar circle everywhere else, so a photo already shown there paints
/// instantly without a second download.
class ProfilePhotoViewerScreen extends StatefulWidget {
  const ProfilePhotoViewerScreen({
    super.key,
    required this.photos,
    required this.initialIndex,
  });

  final List<ProfilePhoto> photos;
  final int initialIndex;

  @override
  State<ProfilePhotoViewerScreen> createState() =>
      _ProfilePhotoViewerScreenState();
}

/// Stateful purely to own the [PageController]. It used to be built inline in
/// a [StatelessWidget]'s `build()`, which meant a fresh controller — seeded at
/// `initialIndex` — on every rebuild: the viewer snapped back to the photo it
/// was opened on whenever the system theme, text scale or orientation changed,
/// and each discarded controller was a [ChangeNotifier] nobody disposed. Every
/// other controller in this app is owned by a [State]; this was the exception.
class _ProfilePhotoViewerScreenState extends State<ProfilePhotoViewerScreen> {
  late final _pageController = PageController(initialPage: widget.initialIndex);

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.photos.length,
        itemBuilder: (context, index) =>
            _ViewerPage(path: widget.photos[index].storagePath),
      ),
    );
  }
}

class _ViewerPage extends ConsumerWidget {
  const _ViewerPage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytesAsync = ref.watch(avatarBytesProvider(path));
    return Center(
      child: bytesAsync.when(
        data: (bytes) => InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Image.memory(bytes),
        ),
        loading: () => const CircularProgressIndicator(),
        error: (_, _) =>
            const Icon(Icons.broken_image, color: Colors.white54, size: 48),
      ),
    );
  }
}

/// Drag-to-reorder the gallery's display order. Saving replaces every
/// `profile_photos` row for this user (delete+insert, per
/// [ProfileRepository.reorderPhotos]) — the storage objects themselves are
/// never touched.
class ProfilePhotoReorderScreen extends ConsumerStatefulWidget {
  const ProfilePhotoReorderScreen({super.key, required this.photos});

  final List<ProfilePhoto> photos;

  @override
  ConsumerState<ProfilePhotoReorderScreen> createState() =>
      _ProfilePhotoReorderScreenState();
}

class _ProfilePhotoReorderScreenState
    extends ConsumerState<ProfilePhotoReorderScreen> {
  late final List<ProfilePhoto> _order = List.of(widget.photos);
  bool _isSaving = false;

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _order.removeAt(oldIndex);
      _order.insert(newIndex, item);
    });
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      await ref.read(profileRepositoryProvider).reorderPhotos(order: _order);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.failedToReorderPhotosError,
          ),
        ),
      );
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.reorderPhotosTitle),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.saveButton),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ReorderableWrap(
          spacing: 8,
          runSpacing: 8,
          needsLongPressDraggable: true,
          onReorder: _reorder,
          children: [
            for (final photo in _order)
              _PhotoThumb(key: ValueKey(photo.id), path: photo.storagePath),
          ],
        ),
      ),
    );
  }
}

/// Tap-to-select one or more photos, then delete them together. A single
/// confirmation dialog covers the whole batch rather than one per photo.
class ProfilePhotoDeleteScreen extends ConsumerStatefulWidget {
  const ProfilePhotoDeleteScreen({super.key, required this.photos});

  final List<ProfilePhoto> photos;

  @override
  ConsumerState<ProfilePhotoDeleteScreen> createState() =>
      _ProfilePhotoDeleteScreenState();
}

class _ProfilePhotoDeleteScreenState
    extends ConsumerState<ProfilePhotoDeleteScreen> {
  final _selectedIds = <String>{};
  bool _isDeleting = false;

  void _toggle(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  Future<void> _confirmAndDelete() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deletePhotosConfirmTitle),
        content: Text(l10n.deletePhotosConfirmContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isDeleting = true);
    try {
      final toDelete = widget.photos
          .where((p) => _selectedIds.contains(p.id))
          .toList();
      await ref.read(profileRepositoryProvider).deletePhotos(photos: toDelete);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.failedToDeletePhotosError,
          ),
        ),
      );
      setState(() => _isDeleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.deletePhotosTitle),
        actions: [
          IconButton(
            icon: _isDeleting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline),
            tooltip: l10n.deleteButton,
            onPressed: _selectedIds.isEmpty || _isDeleting
                ? null
                : _confirmAndDelete,
          ),
        ],
      ),
      // A lazy grid, not a Wrap inside a SingleChildScrollView. That built
      // every tile at once, so opening this screen on a full 80-photo gallery
      // started 80 simultaneous downloads and 80 decodes before a single tile
      // was on screen. GridView.builder only builds what is visible (plus its
      // cache extent), which is also what makes `avatarBytesProvider`'s
      // per-path fetches arrive a screenful at a time.
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: _thumbSize,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: widget.photos.length,
        itemBuilder: (context, index) {
          final photo = widget.photos[index];
          return _SelectablePhotoThumb(
            key: ValueKey(photo.id),
            path: photo.storagePath,
            selected: _selectedIds.contains(photo.id),
            onTap: () => _toggle(photo.id),
          );
        },
      ),
    );
  }
}

class _PhotoThumb extends ConsumerWidget {
  const _PhotoThumb({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(avatarBytesProvider(path)).value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: _thumbSize,
        height: _thumbSize,
        child: bytes != null
            ? Image(
                image: sizedMemoryImage(
                  context,
                  bytes,
                  logicalWidth: _thumbSize,
                ),
                fit: BoxFit.cover,
              )
            : Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
      ),
    );
  }
}

class _SelectablePhotoThumb extends ConsumerWidget {
  const _SelectablePhotoThumb({
    super.key,
    required this.path,
    required this.selected,
    required this.onTap,
  });

  final String path;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(avatarBytesProvider(path)).value;
    final primary = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: _thumbSize,
        height: _thumbSize,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: bytes != null
                  ? Image(
                      image: sizedMemoryImage(
                        context,
                        bytes,
                        logicalWidth: _thumbSize,
                      ),
                      fit: BoxFit.cover,
                    )
                  : Container(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                    ),
            ),
            if (selected)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: primary, width: 3),
                ),
              ),
            Positioned(
              top: 4,
              right: 4,
              child: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? primary : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
