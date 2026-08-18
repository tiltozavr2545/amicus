import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/network_timeout.dart';
import '../auth/auth_providers.dart';

class UserActivityRepository {
  UserActivityRepository(this._client);

  final SupabaseClient _client;

  /// Records "the app was just opened" server-side, via `touch_user_activity()`
  /// (migration `20260819190000`) — the digest push reads this to count only
  /// posts that appeared after the viewer was last around to see them,
  /// instead of a running tally that never checked.
  Future<void> touch() {
    return _client.rpc('touch_user_activity').timeout(networkTimeout);
  }
}

final userActivityRepositoryProvider = Provider<UserActivityRepository>((ref) {
  return UserActivityRepository(ref.watch(supabaseClientProvider));
});

/// Fire-and-forget, once per signed-in user — same shape and same call site
/// (`MainShellScreen`) as [pushRegistrationProvider]. Not autoDispose: this
/// should fire once per app open, not once per screen that happens to watch
/// it.
final userActivityProvider = FutureProvider<void>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return;
  await ref.read(userActivityRepositoryProvider).touch();
});
