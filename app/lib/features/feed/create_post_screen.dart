import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:reorderables/reorderables.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as video_thumbnail;

import '../../l10n/app_localizations.dart';
import '../../shared/file_extension.dart';
import '../../shared/picker_limit.dart';
import '../../shared/sized_memory_image.dart';
import '../auth/auth_providers.dart';
import 'feed_repository.dart';

const _maxMediaCount = 20;
const _maxVideoDuration = Duration(seconds: 60);

/// Mirrors the `media` bucket's own `file_size_limit` (20260820130000).
///
/// Duration alone was never the whole gate: 45 s of 4K/60 clears
/// [_maxVideoDuration] and still runs well past 100 MiB, and Storage answers
/// that with a 413 only after the entire file has been read into memory and
/// pushed over the network. The composer showed the generic "failed to
/// publish" for it, so the clip looked like a flaky upload rather than one
/// that can never succeed, and retrying could not help.
const _maxVideoBytes = 100 * 1024 * 1024;
const _videoExtensions = {'mp4', 'mov', 'm4v', '3gp', 'webm', 'mkv'};

/// One tile in the composer's media grid: either a photo/video already on
/// the post being edited ([_ExistingSlot]) or one freshly picked in this
/// session ([_PickedSlot]). [key] is stable across reorders/rebuilds — it's
/// what [ReorderableWrap] uses to track which tile moved where.
sealed class _Slot {
  const _Slot(this.key);
  final String key;

  bool get isVideo;
}

class _ExistingSlot extends _Slot {
  const _ExistingSlot(super.key, this.media);
  final PostMedia media;

  @override
  bool get isVideo => media.mediaType == MediaType.video;
}

class _PickedSlot extends _Slot {
  const _PickedSlot(super.key, this.pending, this.previewBytes);
  final PendingMedia pending;

  /// What the grid tile paints: the picked image's own bytes, or (for video)
  /// the generated poster frame — a live [VideoPlayerController] per grid
  /// tile would be needless cost for a preview nobody is meant to play here.
  final Uint8List previewBytes;

  @override
  bool get isVideo => pending.mediaType == MediaType.video;
}

/// Composes a new post, or edits [existingPost] when given — same screen for
/// both, since publishing and saving edits differ only in which repository
/// call they end in and a couple of labels.
class CreatePostScreen extends ConsumerStatefulWidget {
  const CreatePostScreen({super.key, this.existingPost});

  final Post? existingPost;

  @override
  ConsumerState<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends ConsumerState<CreatePostScreen> {
  late final _textController = TextEditingController(
    text: widget.existingPost?.text ?? '',
  );
  late final List<_Slot> _slots = [
    for (final media in widget.existingPost?.media ?? const <PostMedia>[])
      _ExistingSlot(media.id, media),
  ];

  bool get _isEditing => widget.existingPost != null;

  bool _isSubmitting = false;
  bool _isPicking = false;
  String? _errorMessage;

  /// Idempotency key for the submission/edit in flight, and the content
  /// fingerprint it was minted for.
  ///
  /// Kept across retries so a resend after a timeout can't create (or
  /// re-apply) a second time — see [FeedRepository.createPost] — but tied to
  /// *what's being sent*: the server answers a repeat token by doing nothing,
  /// so reusing one after the text changed or the media list was edited would
  /// silently keep the old version while the screen closed as if the new one
  /// had been saved.
  String? _pendingToken;
  String? _pendingFingerprint;

  @override
  void initState() {
    super.initState();
    if (_isEditing) _resolveExistingMediaUrls();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  /// The feed only eagerly resolves a post's *first* slide (see
  /// [FeedRepository.fetchPage]) — the composer needs every existing item
  /// previewable at once, so it resolves whatever's still missing right away.
  /// Every missing path is signed in ONE request, via
  /// [FeedRepository.resolveMediaUrls] — the same batch helper the carousel
  /// already uses (`post_list_view.dart`). Signing them one at a time meant
  /// opening the editor on a full 20-item post fired up to 40 separate
  /// `createSignedUrl` calls, two of them sequential within every video slot.
  ///
  /// Started unawaited from [initState], so a failure here has nowhere to
  /// propagate: without the catch below, opening the editor with no
  /// connectivity threw straight out of an orphaned future and into
  /// `FlutterError.onError`. Every other network call on this screen — and
  /// both of the carousel's copies of this same resolve — already guards
  /// itself; this one was the exception.
  ///
  /// Losing the previews is not losing the photos: an [_ExistingSlot] keeps
  /// its [PostMedia] whatever happens here, and [_submit] sends it on as
  /// [KeptMedia] by `storagePath`. So the slot falls back to its placeholder
  /// tile and saving still keeps the item — the report is there to say why the
  /// tiles are grey, not to warn about data loss.
  Future<void> _resolveExistingMediaUrls() async {
    final missing = <String>{};
    for (final slot in _slots) {
      if (slot is! _ExistingSlot) continue;
      final media = slot.media;
      if (media.url == null) missing.add(media.storagePath);
      if (media.posterPath != null && media.posterUrl == null) {
        missing.add(media.posterPath!);
      }
    }
    if (missing.isEmpty) return;

    final Map<String, String> signed;
    try {
      signed = await ref
          .read(feedRepositoryProvider)
          .resolveMediaUrls(missing.toList());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.failedToLoadPhotosError),
        ),
      );
      return;
    }
    if (!mounted) return;

    final resolved = [
      for (final slot in _slots)
        if (slot is _ExistingSlot)
          _ExistingSlot(
            slot.key,
            slot.media.copyWith(
              // A path the storage API refused to sign is absent from the
              // result; keeping the existing (null) value leaves that slide
              // unresolved rather than failing the whole editor.
              url: slot.media.url ?? signed[slot.media.storagePath],
              posterUrl:
                  slot.media.posterUrl ??
                  (slot.media.posterPath == null
                      ? null
                      : signed[slot.media.posterPath!]),
            ),
          )
        else
          slot,
    ];

    setState(() {
      _slots
        ..clear()
        ..addAll(resolved);
    });
  }

  String get _fingerprint {
    final ids = _slots
        .map(
          (slot) => switch (slot) {
            _ExistingSlot(:final media) => 'existing:${media.id}',
            _PickedSlot(:final pending) => 'picked:${pending.mediaClientToken}',
          },
        )
        .join(',');
    return '${_textController.text.trim()}|$ids';
  }

  bool _looksLikeVideo(XFile file) {
    final mime = file.mimeType;
    if (mime != null) return mime.startsWith('video/');
    return _videoExtensions.contains(fileExtension(file.name));
  }

  Future<void> _pickMedia() async {
    final l10n = AppLocalizations.of(context)!;
    final remaining = _maxMediaCount - _slots.length;
    if (remaining <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.mediaLimitMessage)));
      return;
    }

    // Not `limit: remaining`: the picker rejects a limit below 2 outright.
    // See [pickerLimit] — `take(remaining)` below is the real cap either way.
    final picked = await ImagePicker().pickMultipleMedia(
      maxWidth: 1600,
      limit: pickerLimit(remaining),
    );
    if (picked.isEmpty) return;

    setState(() => _isPicking = true);
    var skippedTooLong = false;
    var skippedTooLarge = false;
    var failed = false;
    final newSlots = <_Slot>[];
    // Per file, not per batch: one unreadable file (an unsupported codec
    // makes initialize() throw, a huge one fails readAsBytes) shouldn't cost
    // the user the other files they picked — and must not escape, or the
    // `finally` below never runs and the Add button stays disabled for the
    // rest of the composer session, with no way back except losing the draft.
    for (final file in picked.take(remaining)) {
      final mediaClientToken = const Uuid().v4();
      try {
        if (_looksLikeVideo(file)) {
          final controller = VideoPlayerController.file(File(file.path));
          Duration duration;
          try {
            await controller.initialize();
            duration = controller.value.duration;
          } finally {
            await controller.dispose();
          }
          if (duration > _maxVideoDuration) {
            skippedTooLong = true;
            continue;
          }
          // Checked before the poster frame is extracted: no point spending a
          // decode on a clip the bucket will refuse.
          if (await file.length() > _maxVideoBytes) {
            skippedTooLarge = true;
            continue;
          }
          final posterBytes =
              await video_thumbnail.VideoThumbnail.thumbnailData(
                video: file.path,
                imageFormat: video_thumbnail.ImageFormat.JPEG,
                maxWidth: 640,
                quality: 70,
              );
          // Couldn't extract a poster frame — skip rather than add a video
          // slide with nothing to show for it in the feed's tap-to-play
          // poster.
          if (posterBytes == null) {
            failed = true;
            continue;
          }
          // No readAsBytes for video: the clip is read at upload time instead
          // (see uploadTolerantFile), so only the one being sent is resident
          // rather than all 20 slots at once for the whole session. Nothing on
          // screen needs those bytes — this composer's preview and the feed's
          // tap-to-play slide both show the poster frame.
          newSlots.add(
            _PickedSlot(
              mediaClientToken,
              PendingMedia(
                mediaClientToken: mediaClientToken,
                mediaType: MediaType.video,
                source: MediaFile(file.path),
                ext: fileExtension(file.name),
                posterBytes: posterBytes,
              ),
              posterBytes,
            ),
          );
        } else {
          final bytes = await file.readAsBytes();
          newSlots.add(
            _PickedSlot(
              mediaClientToken,
              PendingMedia(
                mediaClientToken: mediaClientToken,
                mediaType: MediaType.image,
                source: MediaBytes(bytes),
                ext: fileExtension(file.name),
              ),
              bytes,
            ),
          );
        }
      } catch (_) {
        failed = true;
      }
    }
    if (!mounted) return;
    setState(() {
      _slots.addAll(newSlots);
      _isPicking = false;
    });
    if (skippedTooLong) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.videoTooLongError)));
    } else if (skippedTooLarge) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.videoTooLargeError)));
    } else if (failed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.failedToAddMediaError)));
    }
  }

  void _removeSlot(_Slot slot) => setState(() => _slots.remove(slot));

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final slot = _slots.removeAt(oldIndex);
      _slots.insert(newIndex, slot);
    });
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final text = _textController.text.trim();
    if (text.isEmpty && _slots.isEmpty) {
      setState(() => _errorMessage = l10n.addTextOrPhotoError);
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      final userId = ref.read(currentUserIdProvider)!;
      final fingerprint = _fingerprint;
      if (_pendingToken == null || _pendingFingerprint != fingerprint) {
        _pendingToken = const Uuid().v4();
        _pendingFingerprint = fingerprint;
      }
      final repo = ref.read(feedRepositoryProvider);
      if (_isEditing) {
        final existingPost = widget.existingPost!;
        await repo.updatePost(
          postId: existingPost.id,
          authorId: userId,
          // A legacy post from before `client_token` existed has none of its
          // own to reuse as the upload prefix for newly added media — mint
          // one for this edit session instead (see [Post.clientToken]).
          postClientToken: existingPost.clientToken ?? _pendingToken!,
          text: text,
          finalMedia: [
            for (final slot in _slots)
              switch (slot) {
                _ExistingSlot(:final media) => KeptMedia(media),
                _PickedSlot(:final pending) => NewMedia(pending),
              },
          ],
        );
      } else {
        await repo.createPost(
          clientToken: _pendingToken!,
          authorId: userId,
          text: text,
          media: [
            for (final slot in _slots)
              if (slot is _PickedSlot) slot.pending,
          ],
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      // Guarded like the `finally` below. Nothing stops the user pressing back
      // while an upload is in flight — the composer shows no warning and there
      // is no PopScope — so this State can be gone by the time a timeout
      // lands, and an unguarded setState then throws an unhandled async error.
      if (!mounted) return;
      setState(
        () => _errorMessage = _isEditing
            ? l10n.failedToSaveChangesError
            : l10n.failedToPublishError,
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? l10n.editPostTitle : l10n.newPostTitle),
        actions: [
          TextButton(
            onPressed: _isSubmitting ? null : _submit,
            child: _isSubmitting
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_isEditing ? l10n.saveButton : l10n.publishButton),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _textController,
              maxLines: 5,
              maxLength: 5000,
              decoration: InputDecoration(
                hintText: l10n.whatsNewHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_slots.isNotEmpty)
              _MediaGrid(
                slots: _slots,
                removeTooltip: l10n.removeMediaTooltip,
                onRemove: _removeSlot,
                onReorder: _reorder,
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _isPicking || _slots.length >= _maxMediaCount
                  ? null
                  : _pickMedia,
              icon: _isPicking
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.photo_outlined),
              label: Text(l10n.addMediaButton),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MediaGrid extends StatelessWidget {
  const _MediaGrid({
    required this.slots,
    required this.removeTooltip,
    required this.onRemove,
    required this.onReorder,
  });

  final List<_Slot> slots;
  final String removeTooltip;
  final ValueChanged<_Slot> onRemove;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    return ReorderableWrap(
      spacing: 8,
      runSpacing: 8,
      needsLongPressDraggable: true,
      onReorder: onReorder,
      children: [
        for (final slot in slots)
          _MediaTile(
            key: ValueKey(slot.key),
            slot: slot,
            removeTooltip: removeTooltip,
            onRemove: () => onRemove(slot),
          ),
      ],
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({
    super.key,
    required this.slot,
    required this.removeTooltip,
    required this.onRemove,
  });

  static const _size = 96.0;

  final _Slot slot;
  final String removeTooltip;
  final VoidCallback onRemove;

  Widget _preview(BuildContext context) {
    final placeholder = Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
    return switch (slot) {
      // Through [sizedMemoryImage], not a bare Image.memory: picked photos
      // arrive at `maxWidth: 1600`, so each would decode to ~12 MB of ARGB for
      // a 96 px tile — twenty of them is ~240 MB against a 100 MB ImageCache,
      // which then thrashes and re-decodes on every composer rebuild. Same
      // helper every other small-image site in the app already uses.
      _PickedSlot(:final previewBytes) => Image(
        image: sizedMemoryImage(context, previewBytes, logicalWidth: _size),
        fit: BoxFit.cover,
      ),
      _ExistingSlot(:final media) =>
        media.mediaType == MediaType.video
            ? (media.posterUrl != null
                  ? CachedNetworkImage(
                      imageUrl: media.posterUrl!,
                      cacheKey: media.posterPath,
                      fit: BoxFit.cover,
                    )
                  : placeholder)
            : (media.url != null
                  ? CachedNetworkImage(
                      imageUrl: media.url!,
                      cacheKey: media.storagePath,
                      fit: BoxFit.cover,
                    )
                  : placeholder),
    };
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _preview(context),
          ),
          if (slot.isVideo)
            const Center(
              child: Icon(
                Icons.play_circle_fill,
                color: Colors.white,
                size: 32,
              ),
            ),
          Positioned(
            top: 2,
            right: 2,
            child: Tooltip(
              message: removeTooltip,
              child: InkWell(
                onTap: onRemove,
                customBorder: const CircleBorder(),
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(2),
                  child: const Icon(Icons.close, color: Colors.white, size: 16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
