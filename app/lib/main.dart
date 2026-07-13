import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'l10n/app_localizations.dart';

const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Date formatting (month names etc.) is locale-specific and loaded
  // separately from AppLocalizations — prime data for every locale the app
  // supports so DateFormat never silently falls back to English.
  for (final locale in AppLocalizations.supportedLocales) {
    await initializeDateFormatting(locale.languageCode);
  }
  await Supabase.initialize(
    url: _supabaseUrl,
    publishableKey: _supabaseAnonKey,
    // Password recovery is completed on reset-password.html — a browser
    // page on a different device/context than the one that requested the
    // link. PKCE (the default) needs the code verifier the requesting
    // client stored locally, which that page can never have, so recovery
    // links would always dead-end there. Implicit flow puts the session
    // tokens straight in the redirect URL instead, which the page can read.
    authOptions: const FlutterAuthClientOptions(
      authFlowType: AuthFlowType.implicit,
    ),
  );
  runApp(const ProviderScope(child: KrugApp()));
}
