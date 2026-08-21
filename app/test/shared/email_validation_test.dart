import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/shared/email_validation.dart';

void main() {
  group('accepts real addresses', () {
    // Shapes that actually exist in this project's user table, plus the ones
    // a naive regex most often breaks: plus-addressing, dots and digits in the
    // local part, a non-.com TLD, and a subdomain.
    const valid = [
      'toptim2545@gmail.com',
      'm.kosovova@gmail.com',
      'lerapomog@yandex.ru',
      'gustavolynch.81387@gmail.com',
      'user+amicus@gmail.com',
      'first.last@mail.co.uk',
      'someone@mail.yandex.com',
      "o'brien!weird#chars@example-domain.org",
    ];
    for (final email in valid) {
      test(email, () => expect(validateEmail(email), isNull));
    }
  });

  group('rejects malformed input', () {
    const malformed = {
      'no-at-sign.com': 'missing @',
      'trailing@': 'no domain',
      '@leading.com': 'no local part',
      'two@@at.com': 'doubled @',
      'me@localhost': 'domain without a dot',
      'me@gmail': 'domain without a dot',
      'spaces in@gmail.com': 'space in the local part',
      'me@ gmail.com': 'space in the domain',
      'me@-leading-dash.com': 'label starting with a dash',
    };
    malformed.forEach((email, why) {
      test('$email ($why)', () {
        expect(validateEmail(email), EmailProblem.malformed);
      });
    });
  });

  test('an empty or blank field reports empty, not malformed', () {
    expect(validateEmail(''), EmailProblem.empty);
    expect(validateEmail('   '), EmailProblem.empty);
  });

  group('rejects domains that can never receive mail', () {
    // The three accounts this rule was written for are all example.com.
    const undeliverable = [
      'testuser@example.com',
      'test2@example.com',
      'testuser2@example.com',
      'someone@example.net',
      'someone@example.org',
      'someone@anything.test',
      'someone@anything.invalid',
      'someone@box.local',
    ];
    for (final email in undeliverable) {
      test(email, () {
        expect(validateEmail(email), EmailProblem.undeliverableDomain);
      });
    }
  });

  test('the reserved-domain check ignores case and surrounding space', () {
    expect(
      validateEmail('  TestUser@EXAMPLE.COM  '),
      EmailProblem.undeliverableDomain,
    );
  });

  test('a real domain that merely contains "example" is left alone', () {
    // The rule matches whole domains and whole TLDs, not substrings — nobody
    // at example-corp.com should be locked out by it.
    expect(validateEmail('someone@example-corp.com'), isNull);
    expect(validateEmail('someone@myexample.com'), isNull);
    expect(validateEmail('someone@example.com.br'), isNull);
  });
}
