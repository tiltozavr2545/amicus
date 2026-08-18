import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/network_timeout.dart';
import '../auth/auth_providers.dart';

class PushNotificationsRepository {
  PushNotificationsRepository(this._client);

  final SupabaseClient _client;

  /// Requests notification permission (a no-op prompt on Android below 13,
  /// where it's granted by default) and, if granted, registers this device's
  /// FCM token for [userId] and keeps it current across refreshes.
  ///
  /// Silent no-op if permission is denied — there's no in-app fallback UI for
  /// that; the user can still re-enable it from system settings, and the next
  /// call here (next app start) picks it up.
  Future<void> registerDevice({required String userId}) async {
    final settings = await FirebaseMessaging.instance.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) return;

    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await _upsertToken(userId: userId, token: token);
    }

    // Token rotation (app reinstall, Play Services data reset, etc.) — the
    // old row is left in place rather than deleted; send-push prunes it
    // itself the first time a send to it comes back "unregistered".
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      _upsertToken(userId: userId, token: newToken);
    });
  }

  Future<void> _upsertToken({required String userId, required String token}) {
    return _client
        .from('device_tokens')
        .upsert({'user_id': userId, 'fcm_token': token})
        .timeout(networkTimeout);
  }
}

final pushNotificationsRepositoryProvider =
    Provider<PushNotificationsRepository>((ref) {
      return PushNotificationsRepository(ref.watch(supabaseClientProvider));
    });

/// Fire-and-forget device registration, re-run whenever the signed-in user
/// changes. Not autoDispose: it should stay registered for the app's whole
/// lifetime, not tear down and re-run on every widget that stops watching it.
final pushRegistrationProvider = FutureProvider<void>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return;
  await ref
      .read(pushNotificationsRepositoryProvider)
      .registerDevice(userId: userId);
});
