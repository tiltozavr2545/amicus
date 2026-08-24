/// The file extensions the `media` bucket will actually accept, split by kind.
///
/// These mirror the bucket's own `allowed_mime_types` (migration
/// 20260822260000) — and they have to be checked client-side because Storage
/// derives an object's content type from the extension in its *name*, not from
/// its bytes: an object whose name ends in `.gif` is offered as `image/gif`,
/// which the bucket refuses. The refusal arrives as a plain error the composer
/// can only report as "failed to publish", and since the file will never be
/// acceptable, retrying can never help — the same dead end
/// `_maxVideoBytes` was added to close for oversized clips.
///
/// One declaration rather than a copy per screen: the composer picks post
/// media and the profile screen picks gallery photos, both through
/// `fileExtension()`, and both feed the same bucket.
library;

/// `video/mp4`, `video/quicktime`, `video/x-m4v`, `video/3gpp`, `video/webm`,
/// `video/x-matroska`, in that order.
const videoExtensions = {'mp4', 'mov', 'm4v', '3gp', 'webm', 'mkv'};

/// `image/jpeg`, `image/png`, `image/webp`, `image/heic`, `image/heif`.
///
/// `jpg` and `jpeg` are both here because both name the same `image/jpeg`;
/// [fileExtension] returns whichever the picker happened to hand over (and
/// falls back to `jpg` for a name with no extension at all, which is why an
/// extensionless pick is not rejected here).
const imageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'};
