import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_localizations.dart';

const _localePrefsKey = 'app_locale';

/// Explicit language override chosen in Settings, persisted across restarts.
/// `null` means "follow the device locale" — same null-means-system shape as
/// `ThemeModeNotifier` (app/lib/theme/theme_mode_provider.dart).
class LocaleNotifier extends Notifier<Locale?> {
  @override
  Locale? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_localePrefsKey);
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == stored) {
        state = locale;
        return;
      }
    }
  }

  Future<void> setLocale(Locale? locale) async {
    state = locale;
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.remove(_localePrefsKey);
    } else {
      await prefs.setString(_localePrefsKey, locale.languageCode);
    }
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
