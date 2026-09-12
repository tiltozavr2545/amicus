import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import 'report_repository.dart';

/// Opens the "report this" sheet for [targetId].
///
/// One entry point for all four kinds of target on purpose: the reasons, the
/// wording and the duplicate handling are the same everywhere, and a second
/// copy of this sheet for messages or profiles would drift from the first at
/// the first change to the reason list.
Future<void> showReportSheet(
  BuildContext context, {
  required ReportTargetKind kind,
  required String targetId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => _ReportSheet(kind: kind, targetId: targetId),
  );
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.kind, required this.targetId});

  final ReportTargetKind kind;
  final String targetId;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  ReportReason? _reason;
  final _note = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String _reasonLabel(AppLocalizations l10n, ReportReason reason) {
    switch (reason) {
      case ReportReason.spam:
        return l10n.reportReasonSpam;
      case ReportReason.harassment:
        return l10n.reportReasonHarassment;
      case ReportReason.hate:
        return l10n.reportReasonHate;
      case ReportReason.violence:
        return l10n.reportReasonViolence;
      case ReportReason.sexual:
        return l10n.reportReasonSexual;
      case ReportReason.illegal:
        return l10n.reportReasonIllegal;
      case ReportReason.other:
        return l10n.reportReasonOther;
    }
  }

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _sending) return;
    setState(() => _sending = true);

    // Captured before the await: the sheet closes as soon as the call
    // returns, and reaching for `context` afterwards to find the messenger
    // would be reading a tree this widget has already left.
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final repository = ref.read(reportRepositoryProvider);

    String message;
    try {
      final outcome = await repository.submit(
        kind: widget.kind,
        targetId: widget.targetId,
        reason: reason,
        note: _note.text,
      );
      message = outcome == ReportOutcome.alreadySent
          ? l10n.reportAlreadySentMessage
          : l10n.reportSentMessage;
    } catch (_) {
      message = l10n.failedToReportError;
    }

    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      // The note field pushes the sheet up over the keyboard instead of
      // hiding behind it.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Text(
                l10n.reportSheetTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                l10n.reportSheetSubtitle,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            for (final reason in ReportReason.values)
              RadioListTile<ReportReason>(
                value: reason,
                groupValue: _reason,
                onChanged: _sending
                    ? null
                    : (value) => setState(() => _reason = value),
                title: Text(_reasonLabel(l10n, reason)),
                dense: true,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: TextField(
                controller: _note,
                enabled: !_sending,
                maxLength: 1000,
                maxLines: 3,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: l10n.reportNoteLabel,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: FilledButton(
                onPressed: _reason == null || _sending ? null : _submit,
                child: _sending
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.reportSubmitButton),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
