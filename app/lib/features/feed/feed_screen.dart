import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/content_width.dart';
import '../../shared/amicus_mark.dart';
import '../settings/settings_button.dart';
import 'post_list_view.dart';

class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
        title: Row(
          children: [
            const AmicusMark(size: 26),
            const SizedBox(width: 10),
            Text('Amicus', style: Theme.of(context).textTheme.titleLarge),
          ],
        ),
        actions: const [SettingsButton()],
      ),
      body: ContentWidth(
        child: PostListView(
          header: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Text(
              l10n.postsTitle,
              style: Theme.of(context).textTheme.headlineLarge,
            ),
          ),
          emptyState: (context) => Column(
            children: [
              const SizedBox(height: 48),
              Icon(
                Icons.people_outline,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 20),
              Text(l10n.noPostsYetMessage, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => context.go('/connections'),
                child: Text(l10n.addConnectionsButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
