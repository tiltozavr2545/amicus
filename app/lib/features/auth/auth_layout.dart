import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/amicus_mark.dart';
import '../../shared/content_width.dart';

/// A readable, keyboard-safe form with the same welcome across auth routes.
class AuthLayout extends StatelessWidget {
  const AuthLayout({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ContentWidth(
      maxWidth: 480,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Align(alignment: Alignment.centerLeft, child: AmicusMark()),
            const SizedBox(height: 20),
            Text('Amicus', style: Theme.of(context).textTheme.displayMedium),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context)!.authWelcomeMessage,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 32),
            ...children,
          ],
        ),
      ),
    ),
  );
}
