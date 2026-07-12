import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:amicus/features/connections/connection_duration.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ru');
    Intl.defaultLocale = 'ru';
  });

  final now = DateTime(2026, 7, 12);

  test('less than a day', () {
    expect(
      formatConnectionDuration(
        now.subtract(const Duration(hours: 5)),
        now: now,
      ),
      'Знакомы меньше дня',
    );
  });

  test('days pluralization', () {
    expect(
      formatConnectionDuration(now.subtract(const Duration(days: 1)), now: now),
      'Знакомы 1 день',
    );
    expect(
      formatConnectionDuration(now.subtract(const Duration(days: 3)), now: now),
      'Знакомы 3 дня',
    );
    expect(
      formatConnectionDuration(
        now.subtract(const Duration(days: 11)),
        now: now,
      ),
      'Знакомы 11 дней',
    );
  });

  test('months pluralization', () {
    expect(
      formatConnectionDuration(
        now.subtract(const Duration(days: 30)),
        now: now,
      ),
      'Знакомы 1 месяц',
    );
    expect(
      formatConnectionDuration(
        now.subtract(const Duration(days: 65)),
        now: now,
      ),
      'Знакомы 2 месяца',
    );
    expect(
      formatConnectionDuration(
        now.subtract(const Duration(days: 300)),
        now: now,
      ),
      'Знакомы 10 месяцев',
    );
  });

  test('years pluralization', () {
    expect(
      formatConnectionDuration(
        now.subtract(const Duration(days: 365)),
        now: now,
      ),
      'Знакомы 1 год',
    );
    expect(
      formatConnectionDuration(
        now.subtract(const Duration(days: 800)),
        now: now,
      ),
      'Знакомы 2 года',
    );
    expect(
      formatConnectionDuration(
        now.subtract(const Duration(days: 365 * 12)),
        now: now,
      ),
      'Знакомы 12 лет',
    );
  });

  test('summary appends the connection date', () {
    expect(
      formatConnectionSummary(DateTime(2026, 7, 10), now: now),
      'Знакомы 2 дня — с 10 июл. 2026',
    );
    expect(
      formatConnectionSummary(DateTime(2025, 1, 5), now: now),
      'Знакомы 1 год — с 5 янв. 2025',
    );
  });
}
