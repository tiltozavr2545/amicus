import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/features/auth/sign_in_screen.dart';

void main() {
  testWidgets('SignInScreen shows email, password fields and a submit button', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SignInScreen())),
    );

    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Пароль'), findsOneWidget);
    expect(find.text('Войти'), findsOneWidget);
  });
}
