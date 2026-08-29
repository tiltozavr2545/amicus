import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../l10n/locale_provider.dart';
import '../../shared/app_version.dart';
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
  ///
  /// [locale] is the language send-push should use for this device's
  /// notification text (see `effectiveLocaleCodeProvider`); the caller
  /// re-invokes this whenever it changes so the row stays current, so it only
  /// needs capturing here, not read live inside the listener. [version] is
  /// passed the same way and for the same reason — it cannot change while the
  /// process is alive, so reading it once at the call site is both correct and
  /// what keeps this class free of a platform lookup of its own.
  Future<StreamSubscription<String>?> registerDevice({
    required String userId,
    required String locale,
    required AppVersion version,
  }) async {
    final settings = await FirebaseMessaging.instance.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      return null;
    }

    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await _upsertToken(
        userId: userId,
        token: token,
        locale: locale,
        version: version,
      );
    }

    // Token rotation (app reinstall, Play Services data reset, etc.) — the
    // old row is left in place rather than deleted; send-push prunes it
    // itself the first time a send to it comes back "unregistered".
    //
    // The write is awaited *inside* the callback and its failure caught here,
    // because a stream callback has nobody to hand a rejected future to. Left
    // bare, a token that rotates while the device is offline turned
    // `_upsertToken`'s timeout into an unhandled async error — straight into
    // `FlutterError.onError`, the same shape `_resolveExistingMediaUrls` in
    // the composer had to be guarded against. There is no screen behind this
    // to report to, and nothing to retry against: the row is rewritten by the
    // `registerDevice` call above on the next app start regardless.
    return FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      try {
        await _upsertToken(
          userId: userId,
          token: newToken,
          locale: locale,
          version: version,
        );
      } catch (_) {
        // Offline, or the write timed out. Nothing to say and nowhere to say
        // it — see above.
      }
    });
  }

  /// Removes this device's token from [userId]'s rows, so a different user
  /// signing in on the same device afterward doesn't keep receiving pushes
  /// meant for [userId]. Call before signing out, while the session (and thus
  /// the RLS check `user_id = auth.uid()`) is still valid.
  ///
  /// This is the fast path, no longer the guarantee. It cannot be one: the
  /// caller treats it as best-effort (it must — sign-out has to work offline),
  /// and once the session is gone there is nobody left who is allowed to
  /// delete the row. A sign-out with no connection, or one where the token had
  /// already rotated so `getToken()` no longer names the registered row, left
  /// it behind for good — and the next account on that phone then received the
  /// previous user's notifications, commenter names and digests included,
  /// because `send-push` only prunes a token FCM reports as `UNREGISTERED` and
  /// this one is alive.
  ///
  /// The invariant now belongs to the server: `claim_device_token()` deletes
  /// any row carrying this `fcm_token` under a different user the moment a new
  /// registration arrives (migration 20260826120000). A token identifies an
  /// *install*, and only one account can be signed in here at a time, so the
  /// account that registered last is the only one that may hold it.
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

  Future<void> _upsertToken({
    required String userId,
    required String token,
    required String locale,
    required AppVersion version,
  }) {
    return _client
        .from('device_tokens')
        .upsert({
          'user_id': userId,
          'fcm_token': token,
          'locale': locale,
          // Rewritten on every app open, so it tracks the install rather than
          // recording whatever version first registered this device. That is
          // what lets enqueue_app_update_notifications() tell someone who has
          // already updated from someone who has not.
          'app_version': version.name,
          'app_build': version.build,
        })
        .timeout(networkTimeout);
  }
}

final pushNotificationsRepositoryProvider =
    Provider<PushNotificationsRepository>((ref) {
      return PushNotificationsRepository(ref.watch(supabaseClientProvider));
    });

/// Fire-and-forget device registration, re-run whenever the signed-in user or
/// the effective app language changes (so the row send-push reads for this
/// device's locale never goes stale after a Settings language switch). Not
/// autoDispose: it should stay registered for the app's whole lifetime, not
/// tear down and re-run on every widget that stops watching it.
///
/// The token-refresh subscription from a previous build is cancelled via
/// `ref.onDispose` before the provider rebuilds for the next one, so a stale
/// listener can't keep upserting a device's token under a user who is no
/// longer signed in on it, or under a locale that's no longer current.
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
  final locale = ref.watch(effectiveLocaleCodeProvider);
  if (userId == null) return;
  // Awaited before registering rather than watched: the version cannot change
  // while the app is running, so there is nothing to react to — it just has to
  // be known before the row is written.
  final version = await ref.watch(appVersionProvider.future);
  final subscription = await ref
      .read(pushNotificationsRepositoryProvider)
      .registerDevice(userId: userId, locale: locale, version: version);
  if (!ref.mounted) {
    subscription?.cancel();
    return;
  }
  ref.onDispose(() => subscription?.cancel());
});
