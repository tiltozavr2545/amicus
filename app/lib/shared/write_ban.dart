import 'package:supabase_flutter/supabase_flutter.dart';

/// SQLSTATE raised by the `reject_write_when_banned()` trigger
/// (migration 20260913100000).
///
/// Its own code rather than a standard one: `42501` already means "a policy
/// said no", which the client must keep treating as an ordinary failure, and
/// a banned account needs a different sentence than a network blip. The
/// trigger puts the moment the restriction ends in DETAIL, so the message can
/// name a date instead of leaving the person to guess.
const _writeBannedSqlState = 'AMB01';

/// When this account may write again, or null if [error] is not a write ban
/// (or is one whose DETAIL could not be read).
///
/// Returns local time: the date goes straight into a sentence shown to the
/// person, and `timestamptz` arrives from PostgREST as UTC — the same
/// conversion-at-the-boundary rule the rest of the client follows.
///
/// The unreadable-DETAIL case collapses into null deliberately. The trigger
/// always sets it, so a ban without a date means something upstream changed
/// shape, and the honest answer then is the ordinary failure message rather
/// than a confident sentence with a made-up date in it.
DateTime? writeBanUntil(Object error) {
  if (error is! PostgrestException || error.code != _writeBannedSqlState) {
    return null;
  }
  final detail = error.details;
  if (detail is! String) return null;
  return DateTime.tryParse(detail)?.toLocal();
}
