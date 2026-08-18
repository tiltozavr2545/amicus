import 'dart:async';

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
  /// call here (next app start) picks it up. Returns the token-refresh
  /// subscription so the caller can cancel it when [userId] stops being the
  /// signed-in user — otherwise a later refresh would keep re-upserting this
  /// device's token for a user who is no longer signed in on it.
  Future<StreamSubscription<String>?> registerDevice({
    required String userId,
  }) async {
    final settings = await FirebaseMessaging.instance.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      return null;
    }

    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await _upsertToken(userId: userId, token: token);
    }

    // Token rotation (app reinstall, Play Services data reset, etc.) — the
    // old row is left in place rather than deleted; send-push prunes it
    // itself the first time a send to it comes back "unregistered".
    return FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
      _upsertToken(userId: userId, token: newToken);
    });
  }

  /// Removes this device's token from [userId]'s rows, so a different user
  /// signing in on the same device afterward doesn't keep receiving pushes
  /// meant for [userId]. Call before signing out, while the session (and thus
  /// the RLS check `user_id = auth.uid()`) is still valid.
  Future<void> unregisterDevice({required String userId}) async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) return;
    await _client
        .from('device_tokens')
        .delete()
        .eq('user_id', userId)
        .eq('fcm_token', token)
        .timeout(networkTimeout);
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
///
/// The token-refresh subscription from a previous userId is cancelled via
/// `ref.onDispose` before the provider rebuilds for the next one, so a stale
/// listener can't keep upserting a device's token under a user who is no
/// longer signed in on it.
///
/// `registerDevice` awaits a native permission prompt, which can take
/// arbitrarily long — if the provider gets disposed while that's pending
/// (e.g. the user signs out before responding), `ref` is no longer usable by
/// the time this resumes. Calling `ref.onDispose` at that point would throw
/// (Riverpod's `Ref.onDispose` rejects calls after the provider is
/// unmounted), leaving the subscription that was already created uncancelled
/// — so `ref.mounted` is checked first, and the subscription is cancelled
/// directly in that case instead.
final pushRegistrationProvider = FutureProvider<void>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return;
  final subscription = await ref
      .read(pushNotificationsRepositoryProvider)
      .registerDevice(userId: userId);
  if (!ref.mounted) {
    subscription?.cancel();
    return;
  }
  ref.onDispose(() => subscription?.cancel());
});
