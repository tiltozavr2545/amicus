import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/app_localizations.dart';
import 'l10n/locale_provider.dart';
import 'router.dart';
import 'theme/theme_mode_provider.dart';
import 'theme/amicus_theme.dart';

class KrugApp extends ConsumerWidget {
  const KrugApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    return MaterialApp.router(
      title: 'Amicus',
      theme: AmicusTheme.light,
      darkTheme: AmicusTheme.dark,
      themeMode: themeMode,
      // null (the default, until Settings sets an explicit override) makes
      // Flutter pick the first supported locale that matches the device's
      // locale list, falling back to the first entry (en) otherwise. See
      // AppLocalizations.supportedLocales.
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // Without this, the app inherits the device's system font-scale
      // setting uncapped, so a user with a larger accessibility text size
      // gets every row stretched well beyond what the layout was designed
      // for (e.g. a 3-line connection row wrapping to 5 lines). Clamping
      // still lets accessibility scaling through, just bounded.
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 1.0,
        maxScaleFactor: 1.3,
        child: child!,
      ),
      routerConfig: router,
    );
  }
}
