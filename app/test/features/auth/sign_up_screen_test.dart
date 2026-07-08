import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:amicus/features/auth/sign_up_screen.dart';

void main() {
  testWidgets(
    'SignUpScreen shows name, email, password fields and a submit button',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: SignUpScreen())),
      );

      expect(find.text('Имя'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Пароль'), findsOneWidget);
      expect(find.text('Зарегистрироваться'), findsOneWidget);
    },
  );
}
