import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reorderables/reorderables.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/media_pick_message.dart';
import '../../shared/media_picking.dart';
import '../../shared/sized_memory_image.dart';
import '../auth/auth_providers.dart';
import 'feed_repository.dart';

const _maxMediaCount = 20;

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
  const CreatePostScreen({super.key, this.existingPost, this.onClose});

  final Post? existingPost;

  /// How to leave this screen when it isn't a pushed route.
  ///
  /// The main shell shows this screen as its own `body` (see
  /// `MainShellScreen`) so the app's bottom tab bar stays on screen while
  /// composing, instead of pushing a route that would cover it. With no route
  /// of its own, `Navigator.of(context).pop()` would act on whatever screen
  /// is underneath — so callers that embed this widget pass [onClose] to say
  /// what "leave" means instead, and callers that push it as a route (editing
  /// a post) leave this null and get the normal pop.
  /// Carries `true` when a post was created/saved, same as the pop result did.
  final ValueChanged<bool>? onClose;

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

  /// Who will see this post. An edit starts from what the post already says,
  /// so saving an unrelated change cannot quietly widen its audience.
  late PostVisibility _visibility =
      widget.existingPost?.visibility ?? PostVisibility.connections;

  bool _isSubmitting = false;
  bool _isPicking = false;
  String? _errorMessage;

  /// Idempotency key for this composer session's submission.
  ///
  /// Minted once, when the screen opens, and deliberately *not* re-minted when
  /// the draft changes. `create_post_with_media()` treats a repeat token as
  /// "the same submission, here is its current content" and rewrites the post
  /// to whatever arrived last (migration 20260824100000), so one token per
  /// composer session is both safe to retry and incapable of duplicating.
  ///
  /// It used to be re-minted whenever the text or the media list changed,
  /// because the server answered a repeat token by doing nothing and reusing
  /// one would then have discarded the edit. That traded a lost edit for
  /// something worse. `.timeout()` stops waiting without cancelling, so a
  /// publish regularly commits *after* this screen has reported that it
  /// failed — the post is already in every connection's feed and its push has
  /// already gone out. The composer stays open on the draft, and the only
  /// sensible next move (fix the typo, drop a photo, publish again) arrived
  /// under a fresh token and published a **second** post, with a second push
  /// to everyone. The rule about what counts as one submission now lives in
  /// the function, which is the only place that can see both attempts.
  ///
  /// In edit mode this is not an idempotency key at all — [updatePost] sends
  /// the full final state, so a resend is naturally idempotent — and it serves
  /// only as the upload prefix for a legacy post that predates `client_token`
  /// (see [Post.clientToken]). Minting it once matters there too: a token that
  /// changed mid-session moved the prefix, orphaning whatever the previous
  /// attempt had already uploaded.
  late final String _submissionToken = const Uuid().v4();

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

  Future<void> _pickMedia() async {
    final l10n = AppLocalizations.of(context)!;
    final remaining = _maxMediaCount - _slots.length;
    if (remaining <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.mediaLimitMessage)));
      return;
    }

    // Раньше стояло ПОСЛЕ пикера. Пока пикер поднимает свою activity, кнопка
    // «Добавить» оставалась включённой (её `onPressed` смотрит на `_isPicking`
    // и на `_slots.length`, и то и другое — доpick-овое состояние), так что
    // второй тап открывал второй пикер. Оба батча потом обрезались через
    // `take(remaining)` по ОДНОМУ И ТОМУ ЖЕ `remaining`, посчитанному до
    // первого выбора, и вместе могли перевалить за [_maxMediaCount] —
    // публикация после этого падала на серверном `post_media_limit_exceeded`,
    // а композер умел показать только общее «не удалось опубликовать».
    setState(() => _isPicking = true);

    final MediaPickResult result;
    try {
      result = await pickMediaFiles(remaining: remaining);
    } catch (_) {
      // Теперь, когда флаг выставлен заранее, бросок отсюда запирал бы кнопку
      // до конца сессии композера. Заодно перестаёт быть необработанной
      // асинхронной ошибкой: `_pickMedia` зовут как `VoidCallback`, так что
      // ловить этот Future некому.
      if (!mounted) return;
      setState(() => _isPicking = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.failedToAddMediaError)));
      return;
    }
    // The picker hands control to a separate activity, so this State can be
    // gone by the time it resolves — same window every other `await` on this
    // screen already guards against, and the only one that did not.
    if (!mounted) return;

    setState(() {
      _slots.addAll(result.items.map(_slotFor));
      _isPicking = false;
    });
    if (mediaPickProblemMessage(result.firstProblem, l10n)
        case final message?) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  _PickedSlot _slotFor(PickedMedia item) => _PickedSlot(
    item.token,
    PendingMedia(
      mediaClientToken: item.token,
      mediaType: item.isVideo ? MediaType.video : MediaType.image,
      source: item.isVideo
          ? MediaFile(item.filePath!)
          : MediaBytes(item.bytes!),
      ext: item.ext,
      posterBytes: item.posterBytes,
    ),
    item.previewBytes,
  );

  void _close(bool result) {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose(result);
    } else {
      Navigator.of(context).pop(result);
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
      final repo = ref.read(feedRepositoryProvider);
      if (_isEditing) {
        final existingPost = widget.existingPost!;
        await repo.updatePost(
          postId: existingPost.id,
          authorId: userId,
          // A legacy post from before `client_token` existed has none of its
          // own to reuse as the upload prefix for newly added media — this
          // session's token stands in instead (see [Post.clientToken]).
          postClientToken: existingPost.clientToken ?? _submissionToken,
          text: text,
          visibility: _visibility,
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
          clientToken: _submissionToken,
          authorId: userId,
          text: text,
          media: [
            for (final slot in _slots)
              if (slot is _PickedSlot) slot.pending,
          ],
          visibility: _visibility,
        );
      }
      if (mounted) _close(true);
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
            if (_slots.isNotEmpty) ...[
              const SizedBox(height: 12),
              _MediaGrid(
                slots: _slots,
                removeTooltip: l10n.removeMediaTooltip,
                onRemove: _removeSlot,
                onReorder: _reorder,
              ),
            ],
            const SizedBox(height: 16),
            Text(
              l10n.postVisibilityLabel,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            // A segmented button, not a checkbox: these are two audiences to
            // choose between, not a flag to switch on — and both of them are
            // always worth naming, so nobody has to remember what the
            // unticked state meant.
            SegmentedButton<PostVisibility>(
              segments: [
                ButtonSegment(
                  value: PostVisibility.connections,
                  icon: const Icon(Icons.people_outline),
                  label: Text(l10n.visibilityConnectionsLabel),
                ),
                ButtonSegment(
                  value: PostVisibility.favorites,
                  icon: const Icon(Icons.star_outline),
                  label: Text(l10n.visibilityFavoritesLabel),
                ),
              ],
              selected: {_visibility},
              onSelectionChanged: _isSubmitting
                  ? null
                  : (selection) =>
                        setState(() => _visibility = selection.first),
            ),
            const SizedBox(height: 4),
            Text(
              _visibility == PostVisibility.favorites
                  ? l10n.visibilityFavoritesDescription
                  : l10n.visibilityConnectionsDescription,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isEditing ? l10n.saveButton : l10n.publishButton),
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
