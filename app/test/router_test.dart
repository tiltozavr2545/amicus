import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/router.dart';

void main() {
  group('computeRedirect', () {
    test('sends a logged-out user on a non-auth screen to sign-in', () {
      expect(computeRedirect(loggedIn: false, location: '/'), '/sign-in');
      expect(
        computeRedirect(loggedIn: false, location: '/connections'),
        '/sign-in',
      );
    });

    test('leaves a logged-out user on an auth screen alone', () {
      expect(computeRedirect(loggedIn: false, location: '/sign-in'), null);
      expect(computeRedirect(loggedIn: false, location: '/sign-up'), null);
    });

    test('sends a logged-in user away from an auth screen', () {
      expect(computeRedirect(loggedIn: true, location: '/sign-in'), '/');
      expect(computeRedirect(loggedIn: true, location: '/sign-up'), '/');
    });

    test('leaves a logged-in user on a non-auth screen alone', () {
      expect(computeRedirect(loggedIn: true, location: '/'), null);
      expect(computeRedirect(loggedIn: true, location: '/connections'), null);
    });
  });
}
