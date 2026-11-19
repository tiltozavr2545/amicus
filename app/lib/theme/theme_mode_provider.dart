import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/local_preferences.dart';
import '../shared/preference_writes.dart';

const _themeModePrefsKey = 'theme_mode';

/// Explicit appearance preference; system follows device brightness.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  late PreferenceWrites<ThemeMode> _writes;

  @override
  ThemeMode build() {
    final prefs = ref.watch(localPreferencesProvider);
    final initial = prefs == null ? ThemeMode.system : _read(prefs);
    _changed = false;
    _writes = PreferenceWrites(initial);
    if (prefs == null) _load(_writes);
    return initial;
  }

  ThemeMode _read(SharedPreferences prefs) {
    final stored = prefs.getString(_themeModePrefsKey);
    return ThemeMode.values.firstWhere(
      (mode) => mode.name == stored,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> _load(PreferenceWrites<ThemeMode> writes) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || !identical(writes, _writes)) return;
      final saved = _read(prefs);
      writes.persisted = saved;
      if (!_changed) state = saved;
    } catch (_) {
      // Keep defaults available if the optional local store cannot be read.
    }
  }

  bool _changed = false;

  Future<void> setMode(ThemeMode mode) {
    _changed = true;
    final writes = _writes;
    state = mode;
    return writes.save(
      mode,
      () async {
        final prefs =
            ref.read(localPreferencesProvider) ??
            await SharedPreferences.getInstance();
        return prefs.setString(_themeModePrefsKey, mode.name);
      },
      (saved) {
        if (ref.mounted && identical(writes, _writes)) state = saved;
      },
    );
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);
