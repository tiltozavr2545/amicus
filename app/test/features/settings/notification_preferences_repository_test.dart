import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/settings/notification_preferences_repository.dart';

void main() {
  group('NotificationPreferences.fromRow', () {
    test('defaults everything to true when no row exists yet', () {
      final prefs = NotificationPreferences.fromRow(null);

      expect(prefs.systemAccount, true);
      expect(prefs.favorites, true);
      expect(prefs.comments, true);
      expect(prefs.digest, true);
      expect(prefs.inactiveWeek, true);
    });

    test('reads every column from a full row', () {
      final prefs = NotificationPreferences.fromRow({
        'notify_system_account': false,
        'notify_favorites': false,
        'notify_comments': true,
        'notify_digest': false,
        'notify_inactive_week': true,
      });

      expect(prefs.systemAccount, false);
      expect(prefs.favorites, false);
      expect(prefs.comments, true);
      expect(prefs.digest, false);
      expect(prefs.inactiveWeek, true);
    });

    test('a missing column in the row still defaults to true', () {
      final prefs = NotificationPreferences.fromRow({
        'notify_system_account': false,
      });

      expect(prefs.systemAccount, false);
      expect(prefs.favorites, true);
      expect(prefs.comments, true);
      expect(prefs.digest, true);
      expect(prefs.inactiveWeek, true);
    });
  });

  group('NotificationPreferences.copyWith', () {
    test('overrides only the given field', () {
      const prefs = NotificationPreferences();

      final updated = prefs.copyWith(comments: false);

      expect(updated.comments, false);
      expect(updated.systemAccount, true);
      expect(updated.favorites, true);
      expect(updated.digest, true);
      expect(updated.inactiveWeek, true);
    });

    test('each field can be flipped independently', () {
      const allOn = NotificationPreferences();

      expect(allOn.copyWith(systemAccount: false).systemAccount, false);
      expect(allOn.copyWith(favorites: false).favorites, false);
      expect(allOn.copyWith(digest: false).digest, false);
      expect(allOn.copyWith(inactiveWeek: false).inactiveWeek, false);
    });
  });
}
