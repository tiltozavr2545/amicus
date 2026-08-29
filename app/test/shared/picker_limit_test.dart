import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:amicus/shared/picker_limit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pickerLimit', () {
    test('passes a real remaining capacity straight through', () {
      expect(pickerLimit(80), 80);
      expect(pickerLimit(20), 20);
      expect(pickerLimit(2), 2);
    });

    test('drops the limit on the last free slot', () {
      // `limit: 1` is what the picker rejects, so the final slot has to be
      // offered with no limit at all. Callers cap the result themselves.
      expect(pickerLimit(1), isNull);
    });

    test('never produces a value below the picker minimum', () {
      for (var remaining = 1; remaining <= 80; remaining++) {
        final limit = pickerLimit(remaining);
        expect(
          limit == null || limit >= 2,
          isTrue,
          reason: 'remaining=$remaining produced limit=$limit',
        );
      }
    });
  });

  group('the image_picker contract this works around', () {
    // Guards the premise. If image_picker ever accepts 1, pickerLimit is dead
    // weight and should be deleted rather than quietly kept around.
    //
    // Note these throw *synchronously* — the options are validated before the
    // method's first await — so this is `() => call()`, not a Future matcher.
    // That is also why the crash could never be caught by a `try` placed
    // around the awaited result at the call site.
    test('a limit of 1 is rejected before the picker is even opened', () {
      expect(
        () => ImagePicker().pickMultiImage(limit: 1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => ImagePicker().pickMultipleMedia(limit: 1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('what pickerLimit hands back for that same slot is not', () {
      // Gets as far as the (absent, in a unit test) platform channel instead
      // of being rejected up front — that is the distinction that matters.
      // The resulting Future is expected to fail; swallow it so the failure
      // isn't reported as an unhandled async error.
      expect(
        () => ImagePicker()
            .pickMultiImage(limit: pickerLimit(1))
            .catchError((_) => <XFile>[]),
        returnsNormally,
      );
      expect(
        () => ImagePicker()
            .pickMultipleMedia(limit: pickerLimit(1))
            .catchError((_) => <XFile>[]),
        returnsNormally,
      );
    });
  });
}
