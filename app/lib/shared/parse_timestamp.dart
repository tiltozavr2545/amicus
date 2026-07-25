/// Parses a `timestamptz` as it arrives from Supabase and returns it in the
/// device's local zone.
///
/// The `.toLocal()` is the whole point. PostgREST serialises `timestamptz` with
/// an explicit offset (`...Z` or `+00:00`), so `DateTime.parse` hands back a
/// DateTime with `isUtc == true`, and `DateFormat` then prints UTC — a comment
/// written at 13:02 in Moscow was labelled 10:02. For a date-only label ("known
/// since 25 Jul 2026") the same skew can name the wrong day outright.
///
/// Converting here, at the edge where rows become model objects, rather than at
/// each display site, so a new screen can't forget it.
DateTime parseTimestamp(String value) => DateTime.parse(value).toLocal();
