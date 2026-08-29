/// The single private Storage bucket this app uses, for avatars/profile
/// photos (`avatars/<uid>/…`) and post media (`posts/<uid>/…`) alike — see
/// migrations 20260707222025, 20260708172235 and 20260820130000.
///
/// One declaration rather than a private copy per feature: it was spelled out
/// three times (feed, profile, settings), so renaming the bucket meant finding
/// all three.
const mediaBucket = 'media';
