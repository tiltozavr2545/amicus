import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Startup supplies the saved preferences before the first application frame.
/// Embedded widgets can omit the override and load preferences asynchronously.
final localPreferencesProvider = Provider<SharedPreferences?>((ref) => null);
