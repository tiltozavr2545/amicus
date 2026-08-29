/// Counts consecutive activations of a control and reports every [target]th
/// one, then starts over.
///
/// Deliberately knows nothing about which control feeds it or what happens
/// when it fires. It used to live inside `ThemeModeNotifier.toggle`, whose job
/// is to flip light/dark and persist it — so the return type of a theme setter
/// had become an event channel, and the theme layer could not be tested or
/// reused without dragging its consumer's dependencies along.
///
/// Hold one in a plain `Provider` so the count survives rebuilds of whatever
/// widget is doing the counting (a top-bar action is rebuilt constantly).
class TapStreak {
  TapStreak(this.target);

  final int target;
  int _count = 0;

  /// Records one activation. Returns true on every [target]th consecutive
  /// call, resetting the count.
  bool record() {
    _count++;
    if (_count >= target) {
      _count = 0;
      return true;
    }
    return false;
  }
}
