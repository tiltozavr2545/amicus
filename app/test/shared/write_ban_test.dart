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
    // Хранится и едет в UTC, показывается в местной зоне — конвертация на
    // границе, как и у всех остальных timestamptz в этом клиенте.
    expect(until!.isUtc, isFalse);
    expect(until.toUtc(), DateTime.utc(2026, 9, 20, 12, 30));
  });

  group('всё, что не наш бан, читается как отсутствие бана', () {
    test('отказ политики (42501) — обычная ошибка, не бан', () {
      expect(writeBanUntil(_error(code: '42501', details: 'whatever')), isNull);
    });

    test('не PostgrestException вовсе', () {
      expect(writeBanUntil(Exception('no network')), isNull);
    });

    test('бан без разбираемой даты — не выдумываем дату', () {
      expect(
        writeBanUntil(_error(code: 'AMB01', details: 'позавчера')),
        isNull,
      );
      expect(writeBanUntil(_error(code: 'AMB01')), isNull);
    });
  });
}
