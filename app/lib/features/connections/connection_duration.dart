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
  final date = DateFormat('d MMM y', l10n.localeName).format(connectedAt);
  return l10n.connectionSummary(duration, date);
}
