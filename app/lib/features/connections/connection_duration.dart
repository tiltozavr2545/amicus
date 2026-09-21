import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';

/// Formats "known for N days/months/years" from the Connection's creation date.
String formatConnectionDuration(
  AppLocalizations l10n,
  DateTime connectedAt, {
  DateTime? now,
}) {
  final days = (now ?? DateTime.now()).difference(connectedAt).inDays;

  if (days < 1) return l10n.connectionKnownLessThanDay;

  if (days < 30) {
    return l10n.connectionKnownDays(days);
  }

  if (days < 365) {
    return l10n.connectionKnownMonths(days ~/ 30);
  }

  return l10n.connectionKnownYears(days ~/ 365);
}

/// "Known for N days — since 10 Jul 2026", for display under a connection's name.
String formatConnectionSummary(
  AppLocalizations l10n,
  DateTime connectedAt, {
  DateTime? now,
}) {
  final duration = formatConnectionDuration(l10n, connectedAt, now: now);
  final date = _formatConnectionDate(l10n, connectedAt);
  return l10n.connectionSummary(duration, date);
}

/// "since 10 Jul 2026" on its own — the second half of [formatConnectionSummary],
/// split out so a caller can lay the duration and the date out as two
/// independent lines instead of one string with an embedded newline. That
/// matters because a wider text scale can make the duration alone wrap onto
/// two lines; joined into one `Text` with a line cap, that wrap silently
/// swallows the date instead of just truncating the duration.
String formatConnectionSinceDate(AppLocalizations l10n, DateTime connectedAt) {
  return l10n.connectionSinceDate(_formatConnectionDate(l10n, connectedAt));
}

String _formatConnectionDate(AppLocalizations l10n, DateTime connectedAt) {
  return DateFormat('d MMM y', l10n.localeName).format(connectedAt);
}
