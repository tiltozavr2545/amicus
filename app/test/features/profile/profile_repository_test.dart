import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/features/profile/profile_repository.dart';

void main() {
  group('Profile.fromRow', () {
    test('parses a row with an avatar', () {
      final profile = Profile.fromRow({
        'id': 'user-1',
        'name': 'Alice',
        'avatar_path': 'avatars/user-1/avatar.jpg',
      });

      expect(profile.id, 'user-1');
      expect(profile.name, 'Alice');
      expect(profile.avatarPath, 'avatars/user-1/avatar.jpg');
    });

    test('parses a row without an avatar', () {
      final profile = Profile.fromRow({
        'id': 'user-2',
        'name': 'Bob',
        'avatar_path': null,
      });

      expect(profile.avatarPath, null);
    });
  });
}
