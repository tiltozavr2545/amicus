import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:amicus/shared/write_ban.dart';

PostgrestException _error({required String code, String? details}) =>
    PostgrestException(
      message: 'Writing is restricted for this account',
      code: code,
      details: details,
    );

void main() {
  test('the ban is recognised and its date read out of DETAIL', () {
    final until = writeBanUntil(
      _error(code: 'AMB01', details: '2026-09-20T12:30:00Z'),
    );
    expect(until, isNotNull);
    // Stored and transported in UTC, shown in the local zone — converted at
    // the boundary, like every other timestamptz in this client.
    expect(until!.isUtc, isFalse);
    expect(until.toUtc(), DateTime.utc(2026, 9, 20, 12, 30));
  });

  group('anything that is not our ban reads as no ban', () {
    test('a policy denial (42501) is an ordinary error, not a ban', () {
      expect(writeBanUntil(_error(code: '42501', details: 'whatever')), isNull);
    });

    test('not a PostgrestException at all', () {
      expect(writeBanUntil(Exception('no network')), isNull);
    });

    test('a ban without a parseable date — we don\'t invent a date', () {
      expect(
        writeBanUntil(_error(code: 'AMB01', details: 'позавчера')),
        isNull,
      );
      expect(writeBanUntil(_error(code: 'AMB01')), isNull);
    });
  });
}
