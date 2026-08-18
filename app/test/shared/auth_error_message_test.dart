import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:amicus/l10n/app_localizations_en.dart';
import 'package:amicus/shared/auth_error_message.dart';

void main() {
  final l10n = AppLocalizationsEn();

  group('authErrorMessage', () {
    test('maps invalid_credentials', () {
      expect(
        authErrorMessage(
          l10n,
          AuthException('raw', code: 'invalid_credentials'),
        ),
        l10n.invalidCredentialsError,
      );
    });

    test('maps email_not_confirmed', () {
      expect(
        authErrorMessage(
          l10n,
          AuthException('raw', code: 'email_not_confirmed'),
        ),
        l10n.emailNotConfirmedError,
      );
    });

    test(
      'maps both user_already_exists and email_exists to the same message',
      () {
        expect(
          authErrorMessage(
            l10n,
            AuthException('raw', code: 'user_already_exists'),
          ),
          l10n.emailAlreadyRegisteredError,
        );
        expect(
          authErrorMessage(l10n, AuthException('raw', code: 'email_exists')),
          l10n.emailAlreadyRegisteredError,
        );
      },
    );

    test('maps weak_password', () {
      expect(
        authErrorMessage(l10n, AuthException('raw', code: 'weak_password')),
        l10n.weakPasswordError,
      );
    });

    test('maps every rate-limit code to the same message', () {
      for (final code in [
        'over_request_rate_limit',
        'over_email_send_rate_limit',
        'over_sms_send_rate_limit',
      ]) {
        expect(
          authErrorMessage(l10n, AuthException('raw', code: code)),
          l10n.authRateLimitedError,
        );
      }
    });

    test('maps user_banned', () {
      expect(
        authErrorMessage(l10n, AuthException('raw', code: 'user_banned')),
        l10n.accountDisabledError,
      );
    });

    test('falls back to the generic message for an unrecognized code', () {
      expect(
        authErrorMessage(l10n, AuthException('raw', code: 'some_future_code')),
        l10n.unexpectedError,
      );
    });

    test('falls back to the generic message when code is null', () {
      expect(
        authErrorMessage(l10n, AuthException('raw')),
        l10n.unexpectedError,
      );
    });

    test('never surfaces the raw AuthException.message', () {
      final result = authErrorMessage(
        l10n,
        AuthException(
          'some internal Supabase wording nobody should see',
          code: 'invalid_credentials',
        ),
      );
      expect(result, isNot(contains('internal Supabase wording')));
    });
  });
}
