import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_providers.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _sendResetEmail() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      final email = _emailController.text.trim();
      await ref
          .read(supabaseClientProvider)
          .auth
          .resetPasswordForEmail(
            email,
            // Same gh-pages site as email confirmation (see future-development.md
            // on why there's no deep link back into the app yet), but this page
            // is interactive: it reads the recovery tokens from the URL and lets
            // the user actually set a new password via the Supabase JS SDK.
            redirectTo:
                'https://tiltozavr2545.github.io/amicus/reset-password.html',
          );
      if (mounted) {
        setState(
          () => _successMessage =
              'Если аккаунт с email $email существует, на него отправлено письмо со ссылкой для сброса пароля.',
        );
      }
    } on AuthException catch (e) {
      setState(() => _errorMessage = e.message);
    } catch (e) {
      setState(() => _errorMessage = 'Неожиданная ошибка: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Сброс пароля')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Введи email, привязанный к аккаунту, — пришлём ссылку для сброса пароля.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 24),
            if (_errorMessage != null) ...[
              Text(
                _errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 12),
            ],
            if (_successMessage != null) ...[
              Text(
                _successMessage!,
                style: const TextStyle(color: Colors.green),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: _isLoading ? null : _sendResetEmail,
              child: _isLoading
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Отправить ссылку'),
            ),
            TextButton(
              onPressed: () => context.go('/sign-in'),
              child: const Text('Вернуться ко входу'),
            ),
          ],
        ),
      ),
    );
  }
}
