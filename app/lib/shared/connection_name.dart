import 'package:flutter/material.dart';

import '../features/connections/connections_repository.dart';
import '../l10n/app_localizations.dart';

/// A person's name with this viewer's private relationship state.
class ConnectionName extends StatelessWidget {
  const ConnectionName({
    super.key,
    required this.name,
    this.connection,
    this.style,
  });

  final String name;
  final Friend? connection;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    Widget mark(String label, IconData icon, Color color) => Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: label,
        child: Icon(icon, size: 16, color: color),
      ),
    );
    return Row(
      children: [
        Flexible(
          child: Text(
            name,
            style: style,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (connection?.isFavorite ?? false)
          mark(l10n.unfavoriteFriendTooltip, Icons.star, scheme.tertiary),
        if (connection?.isMuted ?? false)
          mark(
            l10n.unmuteFriendTooltip,
            Icons.volume_off_outlined,
            scheme.onSurfaceVariant,
          ),
        if (connection?.isBlocked ?? false)
          mark(l10n.unblockButton, Icons.block, scheme.error),
      ],
    );
  }
}
