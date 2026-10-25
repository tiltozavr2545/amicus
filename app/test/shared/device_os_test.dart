import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/shared/device_os.dart';

const _accepted = [
  'android',
  'ios',
  'macos',
  'windows',
  'linux',
  'fuchsia',
  'web',
];

void main() {
  group('the OS version is read from what the platform calls the release', () {
    // The source is device_info_plus, not Platform.operatingSystemVersion:
    // on Android the latter returns the BUILD identifier
    // (`B4.1-260810-1153` on the A059, the actual system is Android 16), and
    // the first version picked `260810` out of it. The test was green back
    // then precisely because it checked a string I made up, not one the phone
    // returned.
    test('Android: Build.VERSION.RELEASE', () {
      final os = DeviceOs.from(operatingSystem: 'android', release: '16');
      expect(os.platform, 'android');
      expect(os.osVersion, '16');
    });

    test('iOS: UIDevice.systemVersion', () {
      expect(
        DeviceOs.from(operatingSystem: 'ios', release: '18.1').osVersion,
        '18.1',
      );
    });

    test('three parts are kept whole', () {
      expect(
        DeviceOs.from(operatingSystem: 'android', release: '8.1.0').osVersion,
        '8.1.0',
      );
    });

    test('a suffix after the number is dropped, not a parse failure', () {
      expect(
        DeviceOs.from(operatingSystem: 'android', release: '16 QPR1').osVersion,
        '16',
      );
    });

    test('a fourth part is cut off at the CHECK limit', () {
      expect(
        DeviceOs.from(
          operatingSystem: 'android',
          release: '16.0.1.2',
        ).osVersion,
        '16.0.1',
      );
    });
  });

  group('anything the server would reject becomes null', () {
    test('a platform not in the constraint list', () {
      expect(
        DeviceOs.from(operatingSystem: 'haiku', release: '1.0').platform,
        isNull,
      );
    });

    test('a release named by a letter (Android preview)', () {
      expect(
        DeviceOs.from(operatingSystem: 'android', release: 'R').osVersion,
        isNull,
      );
    });

    test('an empty release', () {
      expect(
        DeviceOs.from(operatingSystem: 'android', release: '').osVersion,
        isNull,
      );
    });

    test('the platform reports no release at all', () {
      expect(DeviceOs.from(operatingSystem: 'linux').osVersion, isNull);
    });

    // There is a number in the string, but not at the start — exactly the
    // shape that used to yield `260810`. Now the anchor at the start rejects
    // it.
    test('a number not at the start of the string is not a version', () {
      expect(
        DeviceOs.from(
          operatingSystem: 'android',
          release: 'B4.1-260810-1153',
        ).osVersion,
        isNull,
      );
    });
  });

  test('the normalized result passes the server CHECK', () {
    // The same check as in the DB: anything this pair can produce must be
    // accepted by `push_registration_status_os_version_format`.
    for (final release in ['16', '18.1', '8.1.0', '16 QPR1', '16.0.1.2']) {
      final os = DeviceOs.from(operatingSystem: 'android', release: release);
      expect(os.osVersion, matches(r'^\d+(\.\d+){0,2}$'), reason: release);
    }
    for (final platform in _accepted) {
      expect(DeviceOs.from(operatingSystem: platform).platform, platform);
    }
  });
}
