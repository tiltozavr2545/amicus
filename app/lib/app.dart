import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/app_localizations.dart';
import 'router.dart';
import 'theme/theme_mode_provider.dart';

// Built once at startup, not on every rebuild: ColorScheme.fromSeed runs the
// tonal-palette algorithm, and KrugApp rebuilds on every theme toggle and every
// router change. The seed and its two brightness variants never change, so
// there's no reason to recompute them.
final _lightTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
);
final _darkTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.deepPurple,
    brightness: Brightness.dark,
  ),
);

class KrugApp extends ConsumerWidget {
  const KrugApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'Amicus',
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: themeMode,
      // No explicit `locale:` — Flutter picks the first supported locale
      // that matches the device's locale list, falling back to the first
      // entry (en) otherwise. See AppLocalizations.supportedLocales.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    );
  }
}
