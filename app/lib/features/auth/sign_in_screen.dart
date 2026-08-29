import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/auth_error_message.dart';
import '../../shared/network_timeout.dart';
import 'auth_providers.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await ref
          .read(supabaseClientProvider)
          .auth
          .signInWithPassword(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          )
          .timeout(networkTimeout);
    } on AuthException catch (e) {
      // Guarded like the `finally` below: leaving this screen mid-request
      // disposes this State, and a setState (or an AppLocalizations lookup)
      // on a defunct element is a silent no-op in release — the error would
      // simply never appear.
      if (!mounted) return;
      setState(
        () =>
            _errorMessage = authErrorMessage(AppLocalizations.of(context)!, e),
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _errorMessage = AppLocalizations.of(context)!.unexpectedError,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.signInTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: l10n.passwordLabel,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (_errorMessage != null) ...[
              Text(
                _errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: _isLoading ? null : _signIn,
              child: _isLoading
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.signInButton),
            ),
            TextButton(
              onPressed: () => context.go('/sign-up'),
              child: Text(l10n.noAccountSignUpButton),
            ),
            TextButton(
              onPressed: () => context.go('/forgot-password'),
              child: Text(l10n.forgotPasswordButton),
            ),
          ],
        ),
      ),
    );
  }
}
