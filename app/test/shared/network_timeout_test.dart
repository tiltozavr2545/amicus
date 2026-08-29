import 'package:amicus/shared/network_timeout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('uploadTimeout', () {
    test('a small photo still fails fast, like any other request', () {
      // ~300 KB, what a picked image downscaled to maxWidth 1600 weighs.
      expect(uploadTimeout(300 * 1024), const Duration(seconds: 14));
    });

    test('an empty payload gets exactly the plain network timeout', () {
      expect(uploadTimeout(0), networkTimeout);
    });

    test('a 50 MB clip gets minutes, not the 12 s that broke video posts', () {
      final budget = uploadTimeout(50 * 1024 * 1024);
      expect(budget, greaterThan(const Duration(minutes: 5)));
      expect(budget, lessThan(const Duration(minutes: 15)));
    });

    test('grows with the payload', () {
      expect(
        uploadTimeout(20 * 1024 * 1024),
        lessThan(uploadTimeout(40 * 1024 * 1024)),
      );
    });

    test('a wedged connection cannot hold the composer open forever', () {
      // Far past the bucket's own 100 MiB ceiling, so the cap is what answers.
      expect(
        uploadTimeout(10 * 1024 * 1024 * 1024),
        const Duration(minutes: 15),
      );
    });

    test('the bucket-limit payload stays under the cap', () {
      // 100 MiB is the largest object storage accepts (20260820130000) — it
      // must get a real budget rather than being clamped to the ceiling.
      expect(
        uploadTimeout(100 * 1024 * 1024),
        lessThan(const Duration(minutes: 15)),
      );
    });
  });
}
