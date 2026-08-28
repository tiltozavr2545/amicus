import '../l10n/app_localizations.dart';
import 'media_picking.dart';

/// What to tell the user about a file the picker handed over and
/// [pickMediaFiles] refused.
///
/// One place rather than a `switch` per screen: the post composer and the
/// room chat gate the same bucket by the same rules, so they owe the same
/// answers — and null means "nothing was skipped", which both read as "say
/// nothing".
String? mediaPickProblemMessage(
  MediaPickProblem? problem,
  AppLocalizations l10n,
) => switch (problem) {
  null => null,
  MediaPickProblem.videoTooLong => l10n.videoTooLongError,
  MediaPickProblem.videoTooLarge => l10n.videoTooLargeError,
  MediaPickProblem.unsupportedImage => l10n.unsupportedImageFormatError,
  MediaPickProblem.unsupportedVideo => l10n.unsupportedVideoFormatError,
  MediaPickProblem.failed => l10n.failedToAddMediaError,
};
