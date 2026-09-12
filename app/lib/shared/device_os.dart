import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What this install runs on, normalised for the shape
/// `device_tokens.platform` / `.os_version` accept (and the identical
/// constraints on `push_registration_status`).
///
/// Same contract, and the same reason, as `AppVersion` in `app_version.dart`:
/// both columns carry a CHECK constraint, the row is written by a
/// fire-and-forget upsert, and a constraint violation there would fail
/// *device registration itself* — silently, taking every push with it. So
/// anything the constraint would refuse becomes null here instead of being
/// passed through and rejected server-side.
class DeviceOs {
  const DeviceOs({this.platform, this.osVersion});

  /// `android` / `ios` / … — mirrors `device_tokens_platform_check`, which
  /// lists exactly the values `Platform.operatingSystem` can return, plus
  /// `web`.
  final String? platform;

  /// The OS release as numbers only: `16`, `18.1`, `8.1.0`.
  ///
  /// Read through `device_info_plus` rather than
  /// `Platform.operatingSystemVersion`, and that is not a preference — the
  /// latter is wrong on Android. It answers with the vendor build id there
  /// (`B4.1-260810-1153` on the phone this was caught on, whose release is
  /// Android 16), so parsing a number out of it produced `260810`: a value
  /// that means nothing and looks like a version. Caught only by running on a
  /// real device; the test that was supposed to cover it asserted an invented
  /// string and passed.
  final String? osVersion;

  static const _known = {
    'android',
    'ios',
    'macos',
    'windows',
    'linux',
    'fuchsia',
    'web',
  };

  /// Leading numbers-and-dots of a release string, at most three parts.
  ///
  /// Anchored at the start because the input here *is* the release
  /// (`Build.VERSION.RELEASE`, `UIDevice.systemVersion`), not a sentence to
  /// search — the un-anchored version of this pattern is exactly what turned
  /// Android's build id into a fake version. An Android preview naming itself
  /// `R`, or a release with a suffix like `16 QPR1`, therefore yields `null`
  /// and `16` respectively.
  static final _releasePattern = RegExp(r'^(\d+(?:\.\d+){0,2})');

  static Future<DeviceOs> current() async {
    if (kIsWeb) return const DeviceOs(platform: 'web');
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      return DeviceOs.from(
        operatingSystem: 'android',
        release: (await info.androidInfo).version.release,
      );
    }
    if (Platform.isIOS) {
      return DeviceOs.from(
        operatingSystem: 'ios',
        release: (await info.iosInfo).systemVersion,
      );
    }
    // Desktop and anything else: the platform is worth recording, the release
    // is not worth a third branch until something reads it.
    return DeviceOs.from(operatingSystem: Platform.operatingSystem);
  }

  /// The half with a contract to keep, split out so it can be tested against
  /// what real devices actually answer — `DeviceOs.current()` under
  /// `flutter test` only ever describes the machine running the suite.
  @visibleForTesting
  factory DeviceOs.from({required String operatingSystem, String? release}) {
    final match = release == null ? null : _releasePattern.firstMatch(release);
    return DeviceOs(
      platform: _known.contains(operatingSystem) ? operatingSystem : null,
      osVersion: match?.group(1),
    );
  }
}

/// Async now, unlike the first version of this file: reading the real OS
/// release is a platform-channel call, the same shape as
/// [appVersionProvider]'s.
final deviceOsProvider = FutureProvider<DeviceOs>((ref) => DeviceOs.current());
