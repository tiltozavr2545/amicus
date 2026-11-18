import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/local_preferences.dart';
import '../shared/preference_writes.dart';

/// The same floating/classic choice as Framebook, stored only on this device.
class NavigationStyleNotifier extends Notifier<bool> {
  late PreferenceWrites<bool> _writes;

  @override
  bool build() {
    final prefs = ref.watch(localPreferencesProvider);
    final initial = prefs == null ? true : _read(prefs);
    _changed = false;
    _writes = PreferenceWrites(initial);
    if (prefs == null) _load(_writes);
    return initial;
  }

  bool _read(SharedPreferences prefs) {
    return prefs.getBool('floating_navigation') ?? true;
  }

  Future<void> _load(PreferenceWrites<bool> writes) async {
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

  Future<void> setFloating(bool value) {
    _changed = true;
    final writes = _writes;
    state = value;
    return writes.save(
      value,
      () async {
        final prefs =
            ref.read(localPreferencesProvider) ??
            await SharedPreferences.getInstance();
        return prefs.setBool('floating_navigation', value);
      },
      (saved) {
        if (ref.mounted && identical(writes, _writes)) state = saved;
      },
    );
  }
}

final floatingNavigationProvider =
    NotifierProvider<NavigationStyleNotifier, bool>(
      NavigationStyleNotifier.new,
    );
