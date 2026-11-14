import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The same floating/classic choice as Framebook, stored only on this device.
class NavigationStyleNotifier extends Notifier<bool> {
  int _revision = 0;
  Future<void> _pendingSave = Future.value();

  @override
  bool build() {
    _load();
    return true;
  }

  Future<void> _load() async {
    final revision = _revision;
    final prefs = await SharedPreferences.getInstance();
    if (ref.mounted && revision == _revision) {
      state = prefs.getBool('floating_navigation') ?? true;
    }
  }

  Future<void> setFloating(bool value) async {
    final previous = state;
    final revision = ++_revision;
    state = value;
    final save = _pendingSave.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool('floating_navigation', value)) {
        throw StateError('Could not save navigation preference');
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

final floatingNavigationProvider =
    NotifierProvider<NavigationStyleNotifier, bool>(
      NavigationStyleNotifier.new,
    );
