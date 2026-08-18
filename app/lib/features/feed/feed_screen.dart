import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/theme_toggle_switch.dart';
import '../settings/settings_button.dart';
import 'post_list_view.dart';

class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Amicus'),
        actions: const [ThemeToggleSwitch(), SettingsButton()],
      ),
      body: PostListView(
        emptyState: (context) => Column(
          children: [
            Text(l10n.noPostsYetMessage),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => context.go('/connections'),
              child: Text(l10n.addConnectionsButton),
            ),
          ],
        ),
      ),
    );
  }
}
