import 'package:intl/intl.dart';

String _pluralize(int n, String one, String few, String many) {
  final mod100 = n % 100;
  if (mod100 >= 11 && mod100 <= 14) return many;
  switch (n % 10) {
    case 1:
      return one;
    case 2:
    case 3:
    case 4:
      return few;
    default:
      return many;
  }
}

/// Форматирует «мы знакомы N дней/месяцев/лет» по дате создания Connection.
String formatConnectionDuration(DateTime connectedAt, {DateTime? now}) {
  final days = (now ?? DateTime.now()).difference(connectedAt).inDays;

  if (days < 1) return 'Знакомы меньше дня';

  if (days < 30) {
    return 'Знакомы $days ${_pluralize(days, 'день', 'дня', 'дней')}';
  }

  if (days < 365) {
    final months = days ~/ 30;
    return 'Знакомы $months ${_pluralize(months, 'месяц', 'месяца', 'месяцев')}';
  }

  final years = days ~/ 365;
  return 'Знакомы $years ${_pluralize(years, 'год', 'года', 'лет')}';
}

/// «Знакомы N дней — с 10 июл 2026», для показа под именем знакомого.
String formatConnectionSummary(DateTime connectedAt, {DateTime? now}) {
  final duration = formatConnectionDuration(connectedAt, now: now);
  final date = DateFormat('d MMM y').format(connectedAt);
  return '$duration — с $date';
}
