import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:amicus/features/connections/connection_duration.dart';
import 'package:amicus/l10n/app_localizations_en.dart';
import 'package:amicus/l10n/app_localizations_ru.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('ru');
  });

  final en = AppLocalizationsEn();
  final ru = AppLocalizationsRu();
  final now = DateTime(2026, 7, 12);

  test('less than a day', () {
    expect(
      formatConnectionDuration(
        en,
        now.subtract(const Duration(hours: 5)),
        now: now,
      ),
      'Known for less than a day',
    );
    expect(
      formatConnectionDuration(
        ru,
        now.subtract(const Duration(hours: 5)),
        now: now,
      ),
      'Знакомы меньше дня',
    );
  });

  test('days pluralization', () {
    expect(
      formatConnectionDuration(
        en,
        now.subtract(const Duration(days: 1)),
        now: now,
      ),
      'Known for 1 day',
    );
    expect(
      formatConnectionDuration(
        en,
        now.subtract(const Duration(days: 3)),
        now: now,
      ),
      'Known for 3 days',
    );
    expect(
      formatConnectionDuration(
        en,
        now.subtract(const Duration(days: 11)),
        now: now,
      ),
      'Known for 11 days',
    );

    expect(
      formatConnectionDuration(
        ru,
        now.subtract(const Duration(days: 1)),
        now: now,
      ),
      'Знакомы 1 день',
    );
    expect(
      formatConnectionDuration(
        ru,
        now.subtract(const Duration(days: 3)),
        now: now,
      ),
      'Знакомы 3 дня',
    );
    expect(
      formatConnectionDuration(
        ru,
        now.subtract(const Duration(days: 11)),
        now: now,
      ),
      'Знакомы 11 дней',
    );
  });

  test('months pluralization', () {
    expect(
      formatConnectionDuration(
        en,
        now.subtract(const Duration(days: 30)),
        now: now,
      ),
      'Known for 1 month',
    );
    expect(
      formatConnectionDuration(
        en,
        now.subtract(const Duration(days: 65)),
        now: now,
      ),
      'Known for 2 months',
    );
    expect(
      formatConnectionDuration(
        en,
        now.subtract(const Duration(days: 300)),
        now: now,
      ),
      'Known for 10 months',
    );

    expect(
      formatConnectionDuration(
        ru,
        now.subtract(const Duration(days: 30)),
        now: now,
      ),
      'Знакомы 1 месяц',
    );
    expect(
      formatConnectionDuration(
        ru,
        now.subtract(const Duration(days: 65)),
        now: now,
      ),
      'Знакомы 2 месяца',
    );
    expect(
      formatConnectionDuration(
        ru,
        now.subtract(const Duration(days: 300)),
        now: now,
      ),
      'Знакомы 10 месяцев',
    );
  });

  test('years pluralization', () {
    expect(
      formatConnectionDuration(
        en,
        now.subtract(const Duration(days: 365)),
        now: now,
      ),
      'Known for 1 year',
    );
    expect(
      formatConnectionDuration(
        en,
        now.subtract(const Duration(days: 800)),
        now: now,
      ),
      'Known for 2 years',
    );
    expect(
      formatConnectionDuration(
        en,
        now.subtract(const Duration(days: 365 * 12)),
        now: now,
      ),
      'Known for 12 years',
    );

    expect(
      formatConnectionDuration(
        ru,
        now.subtract(const Duration(days: 365)),
        now: now,
      ),
      'Знакомы 1 год',
    );
    expect(
      formatConnectionDuration(
        ru,
        now.subtract(const Duration(days: 800)),
        now: now,
      ),
      'Знакомы 2 года',
    );
    expect(
      formatConnectionDuration(
        ru,
        now.subtract(const Duration(days: 365 * 12)),
        now: now,
      ),
      'Знакомы 12 лет',
    );
  });

  test('summary appends the connection date', () {
    expect(
      formatConnectionSummary(en, DateTime(2026, 7, 10), now: now),
      'Known for 2 days — since 10 Jul 2026',
    );
    expect(
      formatConnectionSummary(en, DateTime(2025, 1, 5), now: now),
      'Known for 1 year — since 5 Jan 2025',
    );

    expect(
      formatConnectionSummary(ru, DateTime(2026, 7, 10), now: now),
      'Знакомы 2 дня — с 10 июл. 2026',
    );
    expect(
      formatConnectionSummary(ru, DateTime(2025, 1, 5), now: now),
      'Знакомы 1 год — с 5 янв. 2025',
    );
  });
}
