import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/shared/tap_streak.dart';

void main() {
  test('TapStreak fires on the target-th call and not before', () {
    final streak = TapStreak(6);
    for (var i = 1; i < 6; i++) {
      expect(streak.record(), false, reason: 'call $i should not fire');
    }
    expect(streak.record(), true);
  });

  test('TapStreak starts over after firing', () {
    final streak = TapStreak(3);
    expect(
      [streak.record(), streak.record(), streak.record()],
      [false, false, true],
    );
    // The count reset, so the very next call must not fire again.
    expect(
      [streak.record(), streak.record(), streak.record()],
      [false, false, true],
    );
  });

  test('A target of 1 fires on every call', () {
    final streak = TapStreak(1);
    expect(streak.record(), true);
    expect(streak.record(), true);
  });
}
