import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/features/auth/forgot_password_screen.dart';
import 'package:amicus/l10n/app_localizations.dart';

Widget _wrap() => const ProviderScope(
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ForgotPasswordScreen(),
  ),
);

void main() {
  testWidgets('ForgotPasswordScreen shows email field and a submit button', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());

    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Send link'), findsOneWidget);
  });

  // Same property the sign-up guards rely on: no Supabase client is registered
  // in this ProviderScope, so if the check stopped running before
  // resetPasswordForEmail() the call would throw instead of showing a message.
  // A passing test is proof the request never left.
  testWidgets('A reserved domain is rejected before anything is sent', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());

    await tester.enterText(find.byType(TextField).first, 'someone@example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Send link'));
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

    await tester.enterText(find.byType(TextField).first, 'not-an-email');
    await tester.tap(find.widgetWithText(FilledButton, 'Send link'));
    await tester.pump();

    expect(
      find.text("Check the email address \u2014 it doesn't look right."),
      findsOneWidget,
    );
  });

  testWidgets('An empty address is rejected before anything is sent', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());

    await tester.tap(find.widgetWithText(FilledButton, 'Send link'));
    await tester.pump();

    expect(find.text('Enter your email'), findsOneWidget);
  });
}
