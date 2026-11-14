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
      appBar: AppBar(
        title: const Row(
          children: [AmicusMark(size: 32), SizedBox(width: 12), Text('Amicus')],
        ),
        actions: const [SettingsButton()],
      ),
      body: ContentWidth(
        child: PostListView(
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
