import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/shared/parse_timestamp.dart';

void main() {
  group('parseTimestamp', () {
    // Assertions are written against the instant and the isUtc flag rather than
    // an expected wall-clock reading, so they hold in whatever zone the test
    // machine (or CI) happens to run in.
    test('returns a local DateTime, not the UTC one Supabase sends', () {
      final parsed = parseTimestamp('2026-01-01T12:00:00Z');

      expect(parsed.isUtc, isFalse);
      expect(parsed.toUtc(), DateTime.utc(2026, 1, 1, 12));
    });

    test('keeps the instant when the row carries an offset', () {
      final parsed = parseTimestamp('2026-01-01T15:00:00+03:00');

      expect(parsed.isUtc, isFalse);
      expect(parsed.toUtc(), DateTime.utc(2026, 1, 1, 12));
    });

    test('agrees with the local reading of the same instant', () {
      final parsed = parseTimestamp('2026-07-25T10:02:00Z');
      final expected = DateTime.utc(2026, 7, 25, 10, 2).toLocal();

      expect(parsed.hour, expected.hour);
      expect(parsed.day, expected.day);
    });
  });
}
