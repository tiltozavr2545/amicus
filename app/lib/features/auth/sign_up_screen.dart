import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_providers.dart';

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      final client = ref.read(supabaseClientProvider);
      // The public.users row is created by a database trigger on
      // auth.users insert (see handle_new_user()) — it reads the name back
      // out of this metadata. Doing it this way means the profile exists
      // even when email confirmation is pending and no session/JWT exists
      // yet for a client-side insert.
      final response = await client.auth.signUp(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        data: {'name': _nameController.text.trim()},
      );
      // Supabase won't throw for an already-registered email (that would
      // let an attacker enumerate accounts) — it silently returns a user
      // with no identities instead. That's the only signal we get.
      if (response.user != null &&
          (response.user!.identities?.isEmpty ?? false)) {
        setState(
          () =>
              _errorMessage = 'Этот email уже зарегистрирован. Попробуй войти.',
        );
        return;
      }
      // With email confirmation required, signUp() succeeds but doesn't
      // return a session — without this message the screen would just sit
      // there with no sign anything happened.
      if (response.session == null && mounted) {
        setState(
          () => _successMessage =
              'Письмо со ссылкой для подтверждения отправлено на ${_emailController.text.trim()}. '
              'Перейди по ссылке в письме, потом вернись сюда и войди с этим email и паролем.',
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
      appBar: AppBar(title: const Text('Регистрация')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Имя'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Пароль'),
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
              FilledButton(
                onPressed: () => context.go('/sign-in'),
                child: const Text('Перейти ко входу'),
              ),
              const SizedBox(height: 12),
            ] else ...[
              FilledButton(
                onPressed: _isLoading ? null : _signUp,
                child: _isLoading
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Зарегистрироваться'),
              ),
              TextButton(
                onPressed: () => context.go('/sign-in'),
                child: const Text('Уже есть аккаунт? Войти'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
