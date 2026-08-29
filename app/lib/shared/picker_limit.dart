/// Clamps "how many more items may be picked" into something `image_picker`
/// will actually accept as its `limit`.
///
/// `MultiImagePickerOptions`/`MediaOptions` validate `limit` in their
/// constructors and **throw `ArgumentError`** for anything below 2 — so
/// passing the remaining capacity straight through blew up on the very last
/// slot: at 19 of 20 post media (or 79 of 80 profile photos) the remainder is
/// 1, and tapping "add" threw instead of opening a picker, making the final
/// slot unreachable.
///
/// `null` means "no limit" to the picker, which is safe because every call
/// site also clamps what it accepts back (`picked.take(remaining)`) — the
/// limit is a courtesy to the system picker's own UI, never the real gate.
int? pickerLimit(int remaining) => remaining >= 2 ? remaining : null;
