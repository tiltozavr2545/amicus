import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as video_thumbnail;

import 'file_extension.dart';
import 'media_extensions.dart';
import 'picker_limit.dart';

/// How long a video may be. Anything longer is left out of the pick.
const maxVideoDuration = Duration(seconds: 60);

/// Mirrors the `media` bucket's own `file_size_limit` (20260820130000).
///
/// Duration alone was never the whole gate: 45 s of 4K/60 clears
/// [maxVideoDuration] and still runs well past 100 MiB, and Storage answers
/// that with a 413 only after the entire file has been read into memory and
/// pushed over the network. The screen showed a generic "failed" for it, so
/// the clip looked like a flaky upload rather than one that can never
/// succeed, and retrying could not help.
const maxVideoBytes = 100 * 1024 * 1024;

/// One file the picker handed over that this app is actually willing to
/// upload — every gate below has already said yes to it.
///
/// A video carries its [filePath] rather than its bytes: the clip is read at
/// upload time (see `uploadTolerantFile`), so only the one being sent is
/// resident rather than every picked slot at once. Nothing on screen needs
/// those bytes — the composer tile and the chat bubble both show
/// [posterBytes], and the feed's slide starts from the poster too.
class PickedMedia {
  const PickedMedia({
    required this.token,
    required this.isVideo,
    required this.ext,
    this.bytes,
    this.filePath,
    this.posterBytes,
  });

  /// Minted once per pick, not per upload attempt — what makes the item's
  /// storage path deterministic, so a retry addresses the same object
  /// instead of leaving a copy behind.
  final String token;

  final bool isVideo;
  final String ext;

  /// The image's own bytes, read at pick time. Null for video.
  final Uint8List? bytes;

  /// The video's local file path. Null for an image.
  final String? filePath;

  /// JPEG poster frame extracted at pick time. Required for video, always
  /// null for an image.
  final Uint8List? posterBytes;

  /// What a preview tile paints: the image itself, or a video's poster frame
  /// — a live [VideoPlayerController] per tile would be needless cost for a
  /// preview nobody is meant to play there.
  Uint8List get previewBytes => (isVideo ? posterBytes : bytes)!;
}

/// Why a picked file did not make it into [MediaPickResult.items]. Reported
/// one at a time: a batch usually fails for one reason, and a stack of
/// snackbars says less than the first of them.
enum MediaPickProblem {
  videoTooLong,
  videoTooLarge,
  unsupportedImage,
  unsupportedVideo,
  failed,
}

class MediaPickResult {
  const MediaPickResult(this.items, this.problems);

  final List<PickedMedia> items;
  final Set<MediaPickProblem> problems;

  /// The one worth telling the user about, in the order the composer has
  /// always reported them.
  MediaPickProblem? get firstProblem {
    for (final problem in MediaPickProblem.values) {
      if (problems.contains(problem)) return problem;
    }
    return null;
  }
}

bool _looksLikeVideo(XFile file) {
  final mime = file.mimeType;
  if (mime != null) return mime.startsWith('video/');
  return videoExtensions.contains(fileExtension(file.name));
}

/// Opens the system picker and returns at most [remaining] files, each one
/// already checked against everything that can only fail *after* an upload.
///
/// Throws only if the picker itself fails — a file this app won't take is a
/// [MediaPickProblem], not an exception, because the rest of the batch is
/// still worth keeping.
///
/// Shared by the post composer and the room chat: both feed the same bucket,
/// and every gate here is a fact about that bucket rather than about either
/// screen.
Future<MediaPickResult> pickMediaFiles({required int remaining}) async {
  // Not `limit: remaining`: the picker rejects a limit below 2 outright.
  // See [pickerLimit] — `take(remaining)` below is the real cap either way.
  final picked = await ImagePicker().pickMultipleMedia(
    maxWidth: 1600,
    limit: pickerLimit(remaining),
  );

  final items = <PickedMedia>[];
  final problems = <MediaPickProblem>{};

  // Per file, not per batch: one unreadable file (an unsupported codec makes
  // initialize() throw, a huge one fails readAsBytes) shouldn't cost the user
  // the other files they picked.
  for (final file in picked.take(remaining)) {
    final token = const Uuid().v4();
    try {
      if (_looksLikeVideo(file)) {
        // Первым делом, до инициализации плеера и до извлечения постера — и по
        // той же причине, по которой ветка изображений ниже проверяет
        // [imageExtensions]: content type объекта Storage берёт из РАСШИРЕНИЯ
        // в его имени (`lookupMimeType()` в storage_client/src/fetch.dart), а
        // имя строит вызывающий из расширения выбранного файла. Формата,
        // которого нет в `allowed_mime_types` бакета (20260822260000), не
        // будет и после ретрая, так что `.avi`/`.mpg`/`.wmv` уходил в общее
        // «не удалось опубликовать» — и уходил ПОСЛЕ того, как клип целиком
        // прочитали в память и отправили по сети.
        //
        // Проверка нужна и на втором, менее очевидном исходе: у файла без
        // расширения в имени [fileExtension] отдаёт свой дефолтный `jpg`,
        // бакет принимает клип как `image/jpeg` — и остаётся слайд с
        // `media_type = 'video'`, постером и кнопкой play, которая не
        // проигрывает ничего.
        if (!videoExtensions.contains(fileExtension(file.name))) {
          problems.add(MediaPickProblem.unsupportedVideo);
          continue;
        }
        final controller = VideoPlayerController.file(File(file.path));
        Duration duration;
        try {
          await controller.initialize();
          duration = controller.value.duration;
        } finally {
          await controller.dispose();
        }
        if (duration > maxVideoDuration) {
          problems.add(MediaPickProblem.videoTooLong);
          continue;
        }
        // Checked before the poster frame is extracted: no point spending a
        // decode on a clip the bucket will refuse.
        if (await file.length() > maxVideoBytes) {
          problems.add(MediaPickProblem.videoTooLarge);
          continue;
        }
        final posterBytes = await video_thumbnail.VideoThumbnail.thumbnailData(
          video: file.path,
          imageFormat: video_thumbnail.ImageFormat.JPEG,
          maxWidth: 640,
          quality: 70,
        );
        // Couldn't extract a poster frame — skip rather than keep a video
        // with nothing to show for it in a tap-to-play poster.
        if (posterBytes == null) {
          problems.add(MediaPickProblem.failed);
          continue;
        }
        items.add(
          PickedMedia(
            token: token,
            isVideo: true,
            ext: fileExtension(file.name),
            filePath: file.path,
            posterBytes: posterBytes,
          ),
        );
      } else {
        // Checked before the bytes are read, and for the same reason the
        // video branch checks duration and size first: the bucket decides an
        // object's content type from the extension in its name, so a format
        // it doesn't accept is refused on upload no matter what the file
        // actually contains — and refused every retry too. See
        // [imageExtensions].
        if (!imageExtensions.contains(fileExtension(file.name))) {
          problems.add(MediaPickProblem.unsupportedImage);
          continue;
        }
        items.add(
          PickedMedia(
            token: token,
            isVideo: false,
            ext: fileExtension(file.name),
            bytes: await file.readAsBytes(),
          ),
        );
      }
    } catch (_) {
      problems.add(MediaPickProblem.failed);
    }
  }
  return MediaPickResult(items, problems);
}
