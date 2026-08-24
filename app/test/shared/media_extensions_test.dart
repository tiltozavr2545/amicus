import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/shared/file_extension.dart';
import 'package:amicus/shared/media_extensions.dart';

void main() {
  group('media extension allowlists', () {
    test('the fallback extension is one the bucket accepts', () {
      // [fileExtension] answers 'jpg' for a name with no usable extension, and
      // both pickers hand that straight to the allowlist check. If 'jpg' ever
      // left [imageExtensions], every extensionless pick would start being
      // rejected as an unsupported format — which is the opposite of what the
      // fallback is for.
      expect(fileExtension('IMG_4021'), 'jpg');
      expect(imageExtensions, contains(fileExtension('IMG_4021')));
    });

    test('nothing counts as both an image and a video', () {
      // The composer asks `_looksLikeVideo` first and only then checks the
      // image list, so an extension in both sets would be silently unreachable
      // as an image.
      expect(imageExtensions.intersection(videoExtensions), isEmpty);
    });

    test('both spellings of JPEG are accepted', () {
      expect(imageExtensions, containsAll(<String>['jpg', 'jpeg']));
    });

    test('formats the bucket refuses are not on the list', () {
      // `allowed_mime_types` (20260822260000) has no image/gif, image/bmp or
      // image/tiff, and no video/x-msvideo. Storage reads the type off the
      // name, so these can only ever fail on upload.
      expect(imageExtensions, isNot(contains('gif')));
      expect(imageExtensions, isNot(contains('bmp')));
      expect(imageExtensions, isNot(contains('tiff')));
      expect(videoExtensions, isNot(contains('avi')));
    });

    test('every listed extension is lowercase, as fileExtension returns', () {
      for (final ext in {...imageExtensions, ...videoExtensions}) {
        expect(ext, ext.toLowerCase(), reason: '$ext would never match');
      }
    });
  });
}
