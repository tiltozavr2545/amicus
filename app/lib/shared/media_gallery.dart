import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';

/// One photo or video that a gallery can show, whatever it belongs to.
///
/// The `media` bucket is private, so nothing is displayable until its storage
/// path has been signed — hence the two URL fields, which start out null and
/// are filled in by [applySignedUrls] as the viewer approaches the slide.
/// [storagePath] is also the item's identity here: it is stable for the
/// object's whole life, unlike a row id, which reorder can replace under an
/// unchanged file.
abstract interface class GalleryMedia {
  String get storagePath;

  /// Path of the video's poster frame (generated client-side at pick time).
  /// Always null for an image.
  String? get posterPath;

  bool get isVideo;

  /// Signed URL for [storagePath], or null until resolved.
  String? get url;
  String? get posterUrl;

  /// The same item with URLs filled in. Implementations return their own
  /// type; the helpers below cast back to it, which is safe because they only
  /// ever pass an item its own copy.
  GalleryMedia withUrls({String? url, String? posterUrl});
}

/// Signs [paths] and returns URL by path — the storage call, handed in rather
/// than reached for, so this file knows nothing about repositories.
typedef MediaUrlResolver =
    Future<Map<String, String>> Function(List<String> paths);

/// How many slides either side of the current one get their URLs resolved.
///
/// One: the neighbour is signed and loading before it is swiped to, and a
/// whole post's worth of signatures is never spent on slides nobody reaches.
const galleryPrefetchRadius = 1;

bool _needsResolving(GalleryMedia item) =>
    item.url == null || (item.posterPath != null && item.posterUrl == null);

/// Indices around [index] that still need signing and aren't already in
/// flight. Marks them in [resolving] — the caller un-marks them when the
/// round trip ends, so a failure is retried on the next swipe.
List<int> takePendingAround(
  List<GalleryMedia> items,
  int index,
  Set<int> resolving,
) {
  final pending = <int>[];
  for (
    var i = index - galleryPrefetchRadius;
    i <= index + galleryPrefetchRadius;
    i++
  ) {
    if (i < 0 || i >= items.length) continue;
    if (!_needsResolving(items[i])) continue;
    if (!resolving.add(i)) continue;
    pending.add(i);
  }
  return pending;
}

/// Every storage path the given slides are still missing a URL for — a video
/// contributes both its own path and its poster's.
List<String> pathsToSign(List<GalleryMedia> items, Iterable<int> indices) {
  final paths = <String>[];
  for (final i in indices) {
    final item = items[i];
    if (item.url == null) paths.add(item.storagePath);
    final posterPath = item.posterPath;
    if (posterPath != null && item.posterUrl == null) paths.add(posterPath);
  }
  return paths;
}

/// [items] with the freshly signed URLs filled in. Paths missing from
/// [signedByPath] (the storage API refused to sign them) leave their slide
/// untouched, so it stays pending and is retried on the next swipe.
List<T> applySignedUrls<T extends GalleryMedia>(
  List<T> items,
  Iterable<int> indices,
  Map<String, String> signedByPath,
) {
  final updated = List.of(items);
  for (final i in indices) {
    final item = updated[i];
    final posterPath = item.posterPath;
    updated[i] =
        item.withUrls(
              url: item.url ?? signedByPath[item.storagePath],
              posterUrl: posterPath == null
                  ? item.posterUrl
                  : item.posterUrl ?? signedByPath[posterPath],
            )
            as T;
  }
  return updated;
}

/// One slide: a plain image, or a video that starts out as a poster with a
/// play affordance and only becomes an actual [VideoPlayerController] once
/// tapped — never autoplaying while scrolled into view. Its own [State] so
/// the controller is created (and disposed, when the user swipes away and
/// this widget leaves the tree) per slide rather than per post or message.
class MediaSlide extends StatefulWidget {
  const MediaSlide({
    super.key,
    required this.item,
    required this.fit,
    required this.constrainHeight,
    this.isCurrent = true,
    this.onTapImage,
  });

  final GalleryMedia item;
  final BoxFit fit;

  /// Whether this is the slide the viewer is actually looking at.
  ///
  /// It exists because of `allowImplicitScrolling`: the page on either side of
  /// the current one is deliberately kept in the tree so its image is already
  /// downloading before the swipe lands. For an image that is free; for a
  /// *playing video* it meant the clip was neither disposed nor paused when it
  /// was swiped past, so its audio went on playing over the next photo until
  /// the viewer swiped two slides away (or scrolled the whole post off screen)
  /// and the state was finally torn down.
  ///
  /// Losing this flag pauses rather than disposes, so swiping back resumes
  /// where the clip left off instead of restarting it.
  final bool isCurrent;

  /// Whether this slide sits inside a fixed-height frame (a multi-item
  /// carousel, or the fullscreen viewer's own bounded page) — an image only
  /// needs `width: double.infinity` for the fixed-frame case; left off
  /// otherwise so it can size itself to its own natural aspect ratio instead
  /// of stretching to fill an unrelated width.
  final bool constrainHeight;

  /// Opens the fullscreen viewer. Null (or ignored, for video — tapping a
  /// video slide always means play/pause, never zoom) when there's nothing
  /// to expand to.
  final VoidCallback? onTapImage;

  @override
  State<MediaSlide> createState() => _MediaSlideState();
}

class _MediaSlideState extends State<MediaSlide> {
  VideoPlayerController? _controller;

  /// A [_play] is between its tap and its `setState`.
  ///
  /// Needed because `_controller` alone cannot express that window: it stays
  /// null for the whole of `initialize()`, so the poster — and its enabled
  /// play button — is still what's on screen. On a slow connection that is
  /// seconds, and a second tap in it started a *second* controller: the first
  /// one's `setState` painted it, the second one's overwrote the field, and
  /// nothing then held a reference to the first. It was never disposed —
  /// [didUpdateWidget] only disposes on a changed path, [dispose] only sees
  /// the field — so its native player went on decoding and playing audio
  /// underneath the second one until the app was killed.
  bool _isPreparing = false;

  @override
  void didUpdateWidget(covariant MediaSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    // build() short-circuits on a non-null controller, so a State reused for
    // a different item would keep rendering (and playing) the previous clip
    // under the new one. Only the *identity* of the media matters here — a
    // rebuild that merely filled in a resolved URL for the same item must not
    // interrupt playback.
    if (oldWidget.item.storagePath == widget.item.storagePath) {
      // Same clip, but it is no longer the page in view — see [isCurrent].
      final controller = _controller;
      if (controller != null && oldWidget.isCurrent && !widget.isCurrent) {
        unawaited(controller.pause().catchError((Object _) {}));
      }
      return;
    }
    final stale = _controller;
    _controller = null;
    stale?.dispose();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    final url = widget.item.url;
    if (url == null || _isPreparing || _controller != null) return;
    // Captured before the await: this State is reused across slides, so the
    // clip it is showing can change while `initialize()` runs. Without this,
    // a controller prepared for the previous item would be installed under
    // the new one — the same reuse [didUpdateWidget] guards the field against.
    final path = widget.item.storagePath;
    _isPreparing = true;
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await controller.initialize();
    } catch (_) {
      // An unplayable codec, an expired signed URL, no network. Nothing to
      // report beyond leaving the poster and its play button in place —
      // letting this escape would be an unhandled async error *and* would
      // leak the controller, since dispose() only ever runs via State.
      await controller.dispose();
      return;
    } finally {
      // Runs before the `return` above propagates, so the button is never
      // left permanently dead by a clip that failed to open.
      _isPreparing = false;
    }
    if (!mounted || widget.item.storagePath != path) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
    await controller.play();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (!item.isVideo) {
      final image = item.url == null
          ? const Center(child: CircularProgressIndicator())
          : CachedNetworkImage(
              imageUrl: item.url!,
              // The URL is a signed Storage link that gets re-signed
              // (different query string) on every fetch, which would
              // otherwise cache-bust every time even though the underlying
              // photo hasn't changed. Keying on the storage path instead —
              // stable for the object's whole lifetime — means a
              // previously seen photo paints from disk instantly.
              cacheKey: item.storagePath,
              fit: widget.fit,
              width: widget.constrainHeight ? double.infinity : null,
            );
      final onTapImage = widget.onTapImage;
      return onTapImage == null
          ? image
          : GestureDetector(onTap: onTapImage, child: image);
    }

    final controller = _controller;
    if (controller != null) {
      return GestureDetector(
        onTap: () => setState(() {
          controller.value.isPlaying ? controller.pause() : controller.play();
        }),
        child: Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: VideoPlayer(controller),
          ),
        ),
      );
    }

    final poster = Stack(
      fit: StackFit.expand,
      children: [
        if (item.posterUrl != null)
          CachedNetworkImage(
            imageUrl: item.posterUrl!,
            cacheKey: item.posterPath,
            fit: BoxFit.cover,
          )
        else
          const ColoredBox(color: Colors.black12),
        Center(
          child: IconButton(
            iconSize: 56,
            color: Colors.white,
            icon: const Icon(Icons.play_circle_fill),
            tooltip: AppLocalizations.of(context)!.playVideoTooltip,
            onPressed: item.url == null ? null : _play,
          ),
        ),
      ],
    );
    // `StackFit.expand` needs a parent that hands it a bounded, finite size —
    // true inside a fixed frame, but not for a lone video sitting straight in
    // an unconstrained-height column. There's no real aspect ratio to fall
    // back on before the video itself is decoded (only the poster image,
    // whose intrinsic size isn't known synchronously either), so a lone video
    // poster settles for the same 4:5 box the multi-item carousel already
    // uses, rather than crashing the layout.
    return widget.constrainHeight
        ? poster
        : AspectRatio(aspectRatio: 4 / 5, child: poster);
  }
}

/// The tapped-through view: one item per page, pinch-zoomable for photos,
/// tap-to-play for video, on black.
class FullscreenMediaViewer extends StatefulWidget {
  const FullscreenMediaViewer({
    super.key,
    required this.media,
    required this.initialIndex,
    required this.resolve,
  });

  final List<GalleryMedia> media;
  final int initialIndex;
  final MediaUrlResolver resolve;

  @override
  State<FullscreenMediaViewer> createState() => _FullscreenMediaViewerState();
}

class _FullscreenMediaViewerState extends State<FullscreenMediaViewer> {
  late final _pageController = PageController(initialPage: widget.initialIndex);
  late List<GalleryMedia> _items = widget.media;
  final _resolving = <int>{};
  late int _currentIndex = widget.initialIndex;

  @override
  void initState() {
    super.initState();
    _resolveAround(widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Same one-round-trip window as a carousel's: the neighbouring photo is
  /// signed and loading before it's swiped to, not after.
  Future<void> _resolveAround(int index) async {
    final pending = takePendingAround(_items, index, _resolving);
    if (pending.isEmpty) return;
    try {
      final signed = await widget.resolve(pathsToSign(_items, pending));
      if (!mounted) return;
      setState(() => _items = applySignedUrls(_items, pending, signed));
    } catch (_) {
      // Nothing to say beyond the spinner already on screen; un-marked below
      // so the next swipe retries.
    } finally {
      _resolving.removeAll(pending);
    }
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
        itemCount: _items.length,
        allowImplicitScrolling: true,
        // Tracks the page as well as resolving around it: the same
        // keep-the-neighbour-alive behaviour as a carousel, so a video
        // swiped past here needs pausing for the same reason (see
        // [MediaSlide.isCurrent]).
        onPageChanged: (index) {
          setState(() => _currentIndex = index);
          _resolveAround(index);
        },
        itemBuilder: (context, index) {
          final item = _items[index];
          if (item.isVideo) {
            return Center(
              child: MediaSlide(
                item: item,
                fit: BoxFit.contain,
                constrainHeight: false,
                isCurrent: index == _currentIndex,
              ),
            );
          }
          return item.url == null
              ? const Center(child: CircularProgressIndicator())
              : InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Center(
                    child: CachedNetworkImage(
                      imageUrl: item.url!,
                      cacheKey: item.storagePath,
                      fit: BoxFit.contain,
                    ),
                  ),
                );
        },
      ),
    );
  }
}
