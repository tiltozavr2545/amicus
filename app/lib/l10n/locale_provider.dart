import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/local_preferences.dart';
import '../shared/preference_writes.dart';

import 'app_localizations.dart';

const _localePrefsKey = 'app_locale';

/// Explicit language override chosen in Settings, persisted across restarts.
/// `null` means "follow the device locale" — same null-means-system shape as
/// `ThemeModeNotifier` (app/lib/theme/theme_mode_provider.dart).
class LocaleNotifier extends Notifier<Locale?> {
  late PreferenceWrites<Locale?> _writes;

  @override
  Locale? build() {
    final prefs = ref.watch(localPreferencesProvider);
    final initial = prefs == null ? null : _read(prefs);
    _changed = false;
    _writes = PreferenceWrites(initial);
    if (prefs == null) _load(_writes);
    return initial;
  }

  Locale? _read(SharedPreferences prefs) {
    final stored = prefs.getString(_localePrefsKey);
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == stored) return locale;
    }
    return null;
  }

  Future<void> _load(PreferenceWrites<Locale?> writes) async {
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

  Future<void> setLocale(Locale? locale) {
    _changed = true;
    final writes = _writes;
    state = locale;
    return writes.save(
      locale,
      () async {
        final prefs =
            ref.read(localPreferencesProvider) ??
            await SharedPreferences.getInstance();
        return locale == null
            ? prefs.remove(_localePrefsKey)
            : prefs.setString(_localePrefsKey, locale.languageCode);
      },
      (saved) {
        if (ref.mounted && identical(writes, _writes)) state = saved;
      },
    );
  }
}

final localeProvider = NotifierProvider<LocaleNotifier, Locale?>(
  LocaleNotifier.new,
);

/// The language code push notifications should be sent in: the explicit
/// override if one is set, otherwise the device's own locale clamped to what
/// the app (and send-push's templates) support. Reimplements the same
/// fallback `MaterialApp.router` applies internally when `locale:` in
/// app.dart is null, because that resolution only happens inside the widget
/// tree and device registration needs it before any widget exists.
final effectiveLocaleCodeProvider = Provider<String>((ref) {
  final override = ref.watch(localeProvider);
  if (override != null) return override.languageCode;
  final deviceCode = PlatformDispatcher.instance.locale.languageCode;
  final supportedCodes = AppLocalizations.supportedLocales.map(
    (l) => l.languageCode,
  );
  return supportedCodes.contains(deviceCode) ? deviceCode : 'en';
});
