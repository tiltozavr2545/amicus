import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/features/auth/sign_up_screen.dart';
import 'package:amicus/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'SignUpScreen shows name, email, password fields and a submit button',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: SignUpScreen(),
          ),
        ),
      );

      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      // "Sign up" appears twice: the AppBar title and the submit button.
      expect(find.widgetWithText(FilledButton, 'Sign up'), findsOneWidget);
    },
  );
}
