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
}
