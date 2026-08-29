/// Deletes the database rows first and the Storage objects afterwards.
///
/// The rule this encodes, stated once here instead of three times:
/// **a row pointing at a deleted object is a bug everyone sees; an object
/// nothing points at is wasted bytes nobody sees.** So when a delete spans
/// both halves and can fail between them — and it can, because `.timeout()`
/// stops waiting without cancelling — the half that must land first is the
/// one that removes the reference.
///
/// Getting this backwards is not hypothetical. All three call sites had it
/// backwards at once: deleting a post left it a permanently broken image slot
/// in every Connection's feed; deleting profile photos left `users.avatar_path`
/// pointing at bytes that were gone, so the avatar vanished everywhere; and
/// deleting an account destroyed every photo and video the user had before the
/// account itself was gone, then failed and left the account alive. Three
/// copies of one rule, wrong in the same way three times — the shape CLAUDE.md
/// warns about in "правило видимости жило в четырёх копиях".
///
/// [objects] is best-effort by construction: once [rows] has committed, the
/// operation has succeeded from every observer's point of view, and reporting
/// a failed cleanup as a failed delete would be a lie that invites a retry of
/// something already done. A failure in [rows], by contrast, propagates — the
/// caller must not treat it as done, and [objects] never runs.
Future<void> deleteRowsThenObjects({
  required Future<void> Function() rows,
  required Future<void> Function() objects,
}) async {
  await rows();
  try {
    await objects();
  } catch (_) {
    // Orphaned bytes, not a broken reference.
  }
}
