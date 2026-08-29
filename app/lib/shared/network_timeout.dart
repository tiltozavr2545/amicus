/// Applied to every Supabase call (`.timeout(networkTimeout)`) so a stalled
/// request (e.g. sending in airplane mode) surfaces the existing error
/// message within seconds instead of leaving the UI spinning indefinitely.
///
/// Right for a PostgREST call, whose body is a few kilobytes at most. NOT
/// right for a Storage upload — see [uploadTimeout].
const networkTimeout = Duration(seconds: 12);

/// Slowest uplink an upload is still given a chance on: 128 KiB/s, i.e. about
/// 1 Mbit/s. Below that, giving up is the honest answer — a 100 MiB clip at
/// half this rate would take half an hour with nothing on screen but a
/// spinner.
const _minUploadBytesPerSecond = 128 * 1024;

/// Hard ceiling regardless of size, so a wedged connection can't hold the
/// composer open forever.
const _maxUploadTimeout = Duration(minutes: 15);

/// How long an upload of [bytes] bytes is allowed to take.
///
/// [networkTimeout] cannot be used for this and using it was a real bug: the
/// `media` bucket accepts objects up to 100 MiB (20260820130000) and the
/// composer accepts up to 60 s of untranscoded video, which the repository's
/// own note puts at 50–100 MB. Twelve seconds for 50 MB demands ~33 Mbit/s
/// sustained, so every video post failed on an ordinary mobile uplink — and
/// because `.timeout()` stops waiting without cancelling, the abandoned
/// request often landed anyway, which meant the user's third or fourth retry
/// "worked" by colliding with it (`uploadTolerant` treats 409 as success).
///
/// Scales with the payload rather than being a second flat constant: a
/// 300 KB photo still fails fast (14 s) instead of inheriting a video-sized
/// budget, which is what the fast feedback of [networkTimeout] was for.
Duration uploadTimeout(int bytes) {
  final scaled = Duration(
    seconds: networkTimeout.inSeconds + bytes ~/ _minUploadBytesPerSecond,
  );
  return scaled > _maxUploadTimeout ? _maxUploadTimeout : scaled;
}
