import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _themeModePrefsKey = 'theme_mode';

/// Explicit appearance preference; system follows device brightness.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  int _revision = 0;
  Future<void> _pendingSave = Future.value();

  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final revision = _revision;
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted || revision != _revision) return;
    final stored = prefs.getString(_themeModePrefsKey);
    if (stored == ThemeMode.dark.name) {
      state = ThemeMode.dark;
    } else if (stored == ThemeMode.light.name) {
      state = ThemeMode.light;
    }
  }

  /// Serialize disk writes so rapid selections persist in selection order.
  Future<void> setMode(ThemeMode mode) async {
    final previous = state;
    final revision = ++_revision;
    state = mode;
    final save = _pendingSave.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_themeModePrefsKey, mode.name)) {
        throw StateError('Could not save appearance preference');
      }
    });
    _pendingSave = save.catchError((Object _) {});
    try {
      await save;
    } catch (_) {
      if (ref.mounted && revision == _revision) state = previous;
      rethrow;
    }
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
