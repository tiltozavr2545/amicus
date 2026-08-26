import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/auth_error_message.dart';
import '../../shared/email_validation.dart';
import '../../shared/network_timeout.dart';
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
  bool _obscurePassword = true;
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
    final l10n = AppLocalizations.of(context)!;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _errorMessage = l10n.nameRequiredError);
      return;
    }
    // Checked before the request, not after it. A signup to a domain that
    // cannot receive mail — `example.com` and friends are reserved by RFC 2606
    // exactly so they never can — leaves an account that is never confirmed
    // and can never be signed into, and the only sign of trouble is a
    // confirmation link that never arrives.
    final emailProblem = validateEmail(_emailController.text);
    if (emailProblem != null) {
      setState(() => _errorMessage = emailProblemMessage(l10n, emailProblem));
      return;
    }
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
      final response = await client.auth
          .signUp(
            email: _emailController.text.trim(),
            password: _passwordController.text,
            data: {'name': name},
          )
          .timeout(networkTimeout);
      // An already-registered address is deliberately NOT distinguished here.
      //
      // Supabase won't throw for one — it returns a user with no identities,
      // and it does that precisely so the response cannot be used to
      // enumerate accounts. Reading that signal back out and printing "this
      // email is already registered" handed the oracle straight back: point
      // the app (or a replay of this same call — there is no captcha
      // configured) at a list of candidate addresses and get a clean yes/no
      // per address, which for a private social app discloses membership.
      //
      // So both cases fall through to the same message. It is also what
      // actually happened server-side: Supabase sends the existing account a
      // "someone tried to sign up with your address" mail, so "check your
      // inbox" is accurate for the real owner and uninformative to anyone
      // else. Someone who genuinely forgot they had an account is served by
      // the forgot-password screen, which makes the same non-disclosure.
      //
      // (`authErrorMessage` still maps `user_already_exists`/`email_exists` to
      // a distinct message. That path is only reachable when the server itself
      // chooses to throw — i.e. with email confirmation turned off — and at
      // that point the disclosure is the server's decision, not this screen's.)
      if (!mounted) return;
      // With email confirmation required, signUp() succeeds but doesn't
      // return a session — without this message the screen would just sit
      // there with no sign anything happened.
      if (response.session == null) {
        setState(
          () => _successMessage = AppLocalizations.of(
            context,
          )!.confirmationEmailSentMessage(_emailController.text.trim()),
        );
      }
    } on AuthException catch (e) {
      // Guarded like the `finally` below: leaving this screen mid-request
      // (the "Forgot password?" link replaces the route via context.go, which
      // disposes this State) otherwise lands a setState and an
      // AppLocalizations lookup on a defunct element.
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
      appBar: AppBar(title: Text(l10n.signUpTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(labelText: l10n.nameLabel),
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
            if (_successMessage != null) ...[
              Text(
                _successMessage!,
                style: const TextStyle(color: Colors.green),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => context.go('/sign-in'),
                child: Text(l10n.goToSignInButton),
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
                    : Text(l10n.signUpButton),
              ),
              TextButton(
                onPressed: () => context.go('/sign-in'),
                child: Text(l10n.alreadyHaveAccountButton),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
