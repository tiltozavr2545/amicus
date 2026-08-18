import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/app_localizations.dart';

/// Maps a Supabase Auth error to a localized, user-facing message.
///
/// Never falls back to [AuthException.message]: that's Supabase's own raw,
/// English-only wording, which would show up untranslated in this app's
/// otherwise fully ru/en-localized screens — the same reasoning the project
/// already applies to `PostgrestException` (see connections_screen.dart's
/// switch on SQLSTATE rather than `e.message`). An unrecognized code falls
/// through to the generic message, same as any other unexpected failure.
String authErrorMessage(AppLocalizations l10n, AuthException e) {
  return switch (e.code) {
    'invalid_credentials' => l10n.invalidCredentialsError,
    'email_not_confirmed' => l10n.emailNotConfirmedError,
    'user_already_exists' || 'email_exists' => l10n.emailAlreadyRegisteredError,
    'weak_password' => l10n.weakPasswordError,
    'over_request_rate_limit' ||
    'over_email_send_rate_limit' ||
    'over_sms_send_rate_limit' => l10n.authRateLimitedError,
    'user_banned' => l10n.accountDisabledError,
    _ => l10n.unexpectedError,
  };
}
