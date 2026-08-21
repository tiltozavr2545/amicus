import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/features/auth/sign_up_screen.dart';
import 'package:amicus/l10n/app_localizations.dart';

Widget _wrap() => const ProviderScope(
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SignUpScreen(),
  ),
);

void main() {
  testWidgets(
    'SignUpScreen shows name, email, password fields and a submit button',
    (tester) async {
      await tester.pumpWidget(_wrap());

      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      // "Sign up" appears twice: the AppBar title and the submit button.
      expect(find.widgetWithText(FilledButton, 'Sign up'), findsOneWidget);
    },
  );

  // A blank name used to reach the server and land as an empty display name
  // everywhere it is shown. The guard runs before signUp(), so this needs no
  // Supabase client — which is also what makes it worth testing here rather
  // than by hand.
  testWidgets('An empty name is rejected before anything is sent', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());

    await tester.enterText(find.byType(TextField).at(1), 'a@b.co');
    await tester.enterText(find.byType(TextField).at(2), 'password123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign up'));
    await tester.pump();

    expect(find.text('Enter your name'), findsOneWidget);
  });

  testWidgets('A name of only spaces is rejected too', (tester) async {
    await tester.pumpWidget(_wrap());

    await tester.enterText(find.byType(TextField).at(0), '   ');
    await tester.enterText(find.byType(TextField).at(1), 'a@b.co');
    await tester.enterText(find.byType(TextField).at(2), 'password123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign up'));
    await tester.pump();

    expect(find.text('Enter your name'), findsOneWidget);
  });

  // Same property the name guard relies on, and what makes these worth having:
  // no Supabase client is registered in this ProviderScope, so if the check
  // ever stopped running before signUp() the call would blow up instead of
  // showing a message. A passing test is therefore proof nothing was sent.
  testWidgets('A reserved domain is rejected before anything is sent', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());

    await tester.enterText(find.byType(TextField).at(0), 'Test User');
    await tester.enterText(
      find.byType(TextField).at(1),
      'testuser@example.com',
    );
    await tester.enterText(find.byType(TextField).at(2), 'password123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign up'));
    await tester.pump();

    expect(
      find.text("This domain can't receive mail. Enter a real email address."),
      findsOneWidget,
    );
  });

  testWidgets('A malformed address is rejected before anything is sent', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());

    await tester.enterText(find.byType(TextField).at(0), 'Test User');
    await tester.enterText(find.byType(TextField).at(1), 'not-an-email');
    await tester.enterText(find.byType(TextField).at(2), 'password123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign up'));
    await tester.pump();

    expect(
      find.text("Check the email address \u2014 it doesn't look right."),
      findsOneWidget,
    );
  });

  testWidgets('An empty email is rejected before anything is sent', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());

    await tester.enterText(find.byType(TextField).at(0), 'Test User');
    await tester.enterText(find.byType(TextField).at(2), 'password123');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign up'));
    await tester.pump();

    expect(find.text('Enter your email'), findsOneWidget);
  });
}
