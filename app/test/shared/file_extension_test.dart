import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/shared/file_extension.dart';

void main() {
  group('fileExtension', () {
    test('returns the lowercased extension of a normal filename', () {
      expect(fileExtension('photo.JPG'), 'jpg');
      expect(fileExtension('IMG_0421.png'), 'png');
      expect(fileExtension('clip.webp'), 'webp');
    });

    test('uses the last dot when the name has several', () {
      expect(fileExtension('my.holiday.photo.jpeg'), 'jpeg');
    });

    test('defaults to jpg when there is no extension', () {
      expect(fileExtension('IMG_4021'), 'jpg');
      expect(fileExtension('image.'), 'jpg');
    });

    test(
      'defaults to jpg when the trailing segment is too long to be an ext',
      () {
        // A "dot" that is really part of the name, not a separator.
        expect(fileExtension('archive.2026_backup'), 'jpg');
      },
    );
  });
}
