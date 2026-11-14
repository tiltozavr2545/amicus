/// How long a penalty lasts, based on what the console sent.
///
/// A separate module rather than three lines in the handler, for exactly one
/// reason: this is arithmetic over form data, it has edge cases, and they
/// should be verified by a test. While it lived inside `/moderation/ban`
/// there was nothing to check it with, and both cases below reached prod.
///
///   * `Number("неделя")` ("week") is NaN, and `new Date(NaN).toISOString()`
///     throws RangeError. The moderator saw a 500 and "Invalid time value"
///     instead of a reply saying the duration is invalid.
///   * a negative number passed silently and was worse: a `write_banned_until`
///     in the past is a ban lifted the same instant. The console showed a
///     penalty as applied that doesn't exist.

/// Default write-ban length in days, if no duration was sent.
export const defaultWriteBanDays = 7;

/// Default login-ban duration — "forever" in units GoTrue understands.
export const defaultAuthBanDays = 3650;

/// Ceiling in hours (a hundred years): `ban_duration` goes to GoTrue as a
/// string, and it can no longer parse `1e21h`.
const maxAuthBanHours = 876_000;

/// The same hundred years, but in days — and this is a ceiling on INPUT,
/// shared by both durations.
///
/// It isn't here for symmetry. `Number.isFinite` lets `1e9` through, and `1e9`
/// days is `8.64e16` milliseconds, i.e. outside the `Date` range, and
/// `writeBanUntil` would fail on `toISOString()` with the very `RangeError:
/// Invalid time value` this module was created for (see the header).
/// `authBanDuration` is covered against this — it is clamped by
/// `maxAuthBanHours`, and this is verified by a test on `1e9` — but the write
/// ban had no clamp, because there was no shared place to put one.
///
/// It is done as a rejection, not a clamp, and that is a difference in
/// meaning: "forever" is a legitimate intent for a login ban, and it has its
/// own default for that ([defaultAuthBanDays]). But `days: 1e9` in a request
/// is not "forever", it is garbage, and silently turning it into a
/// hundred-year penalty is worse than saying the number is not acceptable.
const maxBanDays = 36_500;

export type BanDays =
  | { ok: true; days: number | null }
  | { ok: false; error: string };

/// `null` means "no duration was sent" — the caller substitutes its default.
export function parseBanDays(raw: unknown): BanDays {
  if (raw === undefined || raw === null || raw === '')
    return { ok: true, days: null };
  const days = Number(raw);
  if (!Number.isFinite(days) || days <= 0) {
    return { ok: false, error: 'days: положительное число суток' };
  }
  if (days > maxBanDays) {
    return { ok: false, error: `days: не больше ${maxBanDays} суток` };
  }
  return { ok: true, days };
}

/// The moment until which writing is forbidden.
///
/// The upper bound is enforced at input ([maxBanDays]), not checked here: this
/// function receives an already parsed number, and a second ceiling in two
/// places would drift apart from the first.
export function writeBanUntil(days: number | null, now: number): string {
  return new Date(now + (days ?? defaultWriteBanDays) * 864e5).toISOString();
}

/// `ban_duration` for GoTrue.
export function authBanDuration(days: number | null): string {
  const hours = Math.min(
    maxAuthBanHours,
    Math.max(1, Math.round((days ?? defaultAuthBanDays) * 24)),
  );
  return `${hours}h`;
}
