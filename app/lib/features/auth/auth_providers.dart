import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  return Supabase.instance.client;
});

/// Emits whenever the auth session changes (sign in, sign out, token refresh).
final authStateChangesProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(supabaseClientProvider).auth.onAuthStateChange;
});

final currentUserIdProvider = Provider<String?>((ref) {
  // Falling back to the client directly (instead of only the stream above)
  // means the very first build already knows about a persisted session.
  ref.watch(authStateChangesProvider);
  return ref.watch(supabaseClientProvider).auth.currentSession?.user.id;
});
