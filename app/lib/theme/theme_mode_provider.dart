import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _themeModePrefsKey = 'theme_mode';

/// Light/dark toggle state, persisted across app restarts. Starts by
/// following the system theme; [_load] then overrides it once a previously
/// toggled preference is read. Once the user flips the switch, that explicit
/// choice sticks instead of following the system setting.
const _toggleStreakTarget = 6;

class ThemeModeNotifier extends Notifier<ThemeMode> {
  int _toggleStreak = 0;

  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_themeModePrefsKey);
    if (stored == ThemeMode.dark.name) {
      state = ThemeMode.dark;
    } else if (stored == ThemeMode.light.name) {
      state = ThemeMode.light;
    }
  }

  /// [systemIsDark] is needed because when [state] is still `system`, the
  /// switch reflects the system brightness rather than an explicit choice —
  /// toggling from there should flip away from whatever is on screen now.
  ///
  /// Returns true once every [_toggleStreakTarget]th consecutive call, then
  /// resets the count — lets the caller react to a run of toggles without
  /// this notifier knowing anything about what that reaction is.
  Future<bool> toggle(bool systemIsDark) async {
    final isDark =
        state == ThemeMode.dark || (state == ThemeMode.system && systemIsDark);
    final next = isDark ? ThemeMode.light : ThemeMode.dark;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModePrefsKey, next.name);

    _toggleStreak++;
    if (_toggleStreak >= _toggleStreakTarget) {
      _toggleStreak = 0;
      return true;
    }
    return false;
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
