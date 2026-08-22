import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:amicus/shared/app_version.dart';

PackageInfo _info({required String version, required String buildNumber}) =>
    PackageInfo(
      appName: 'Amicus',
      packageName: 'com.github.tiltozavr2545.amicus',
      version: version,
      buildNumber: buildNumber,
    );

void main() {
  test('a normal release reports both halves', () {
    final v = AppVersion.fromPackageInfo(
      _info(version: '0.16.4', buildNumber: '38'),
    );
    expect(v.name, '0.16.4');
    expect(v.build, 38);
  });

  // The columns carry CHECK constraints, and device registration is
  // fire-and-forget — a rejected insert would silently cost the user every
  // push they were meant to get. So anything the constraint would refuse
  // becomes null here instead, which the server already reads as "older than
  // anything known".
  group('anything the server would reject becomes null instead', () {
    test('a version name that is not three numbers', () {
      final v = AppVersion.fromPackageInfo(
        _info(version: '0.16.4-beta', buildNumber: '38'),
      );
      expect(v.name, isNull);
      expect(v.build, 38, reason: 'a bad name must not cost us the build');
    });

    test('an empty version name', () {
      expect(
        AppVersion.fromPackageInfo(_info(version: '', buildNumber: '38')).name,
        isNull,
      );
    });

    test('a non-numeric build number', () {
      final v = AppVersion.fromPackageInfo(
        _info(version: '0.16.4', buildNumber: 'unknown'),
      );
      expect(v.build, isNull);
      expect(v.name, '0.16.4', reason: 'a bad build must not cost us the name');
    });

    test('a zero build number, which the CHECK refuses', () {
      expect(
        AppVersion.fromPackageInfo(
          _info(version: '0.16.4', buildNumber: '0'),
        ).build,
        isNull,
      );
    });

    test('a negative build number', () {
      expect(
        AppVersion.fromPackageInfo(
          _info(version: '0.16.4', buildNumber: '-1'),
        ).build,
        isNull,
      );
    });
  });

  test('a two-part version is refused — the constraint wants three', () {
    expect(
      AppVersion.fromPackageInfo(_info(version: '1.0', buildNumber: '5')).name,
      isNull,
    );
  });

  test('larger version numbers are not special-cased', () {
    final v = AppVersion.fromPackageInfo(
      _info(version: '10.20.30', buildNumber: '1234'),
    );
    expect(v.name, '10.20.30');
    expect(v.build, 1234);
  });
}
