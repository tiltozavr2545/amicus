import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';

const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The whole app is Russian-only, so set the default locale once here instead
  // of passing 'ru' to every DateFormat call site (and risking a new one that
  // forgets it and silently falls back to English month names).
  await initializeDateFormatting('ru');
  Intl.defaultLocale = 'ru';
  await Supabase.initialize(
    url: _supabaseUrl,
    publishableKey: _supabaseAnonKey,
  );
  runApp(const ProviderScope(child: KrugApp()));
}
