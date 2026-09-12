import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/network_timeout.dart';
import '../auth/auth_providers.dart';

/// What a report points at. The wire values are the `target_kind` CHECK of
/// `content_reports` — spelled out here rather than derived from the enum
/// name, because `roomMessage` and `room_message` differ and a silent
/// mismatch would be rejected by the constraint at the worst moment.
enum ReportTargetKind {
  post('post'),
  comment('comment'),
  roomMessage('room_message'),
  user('user');

  const ReportTargetKind(this.wire);
  final String wire;
}

/// Mirrors the `reason` CHECK. Closed on purpose: it is what the console
/// groups the queue by, and free text lives in the note instead.
enum ReportReason {
  spam('spam'),
  harassment('harassment'),
  hate('hate'),
  violence('violence'),
  sexual('sexual'),
  illegal('illegal'),
  other('other');

  const ReportReason(this.wire);
  final String wire;
}

enum ReportOutcome { sent, alreadySent }

class ReportRepository {
  ReportRepository(this._client);

  final SupabaseClient _client;

  /// Files a report. Returns [ReportOutcome.alreadySent] instead of throwing
  /// when this person has already reported this object.
  ///
  /// The duplicate is a unique-index collision (23505), and treating it as an
  /// error would be wrong twice over: the user did nothing wrong, and the
  /// state they wanted is already true. Same reading as a repeated message
  /// send — the row it collided with *is* the answer. There is no `upsert`
  /// here for the same reason there is none there: rewriting a report would
  /// need an UPDATE right nobody has, and nothing about it wants rewriting.
  ///
  /// Nothing is read back: `content_reports` has no SELECT grant at all, by
  /// design. The confirmation is this method returning.
  Future<ReportOutcome> submit({
    required ReportTargetKind kind,
    required String targetId,
    required ReportReason reason,
    String? note,
  }) async {
    final trimmed = note?.trim();
    try {
      await _client
          .from('content_reports')
          .insert({
            'reporter_id': _client.auth.currentUser!.id,
            'target_kind': kind.wire,
            'target_id': targetId,
            'reason': reason.wire,
            if (trimmed != null && trimmed.isNotEmpty) 'note': trimmed,
          })
          .timeout(networkTimeout);
      return ReportOutcome.sent;
    } on PostgrestException catch (error) {
      if (error.code == '23505') return ReportOutcome.alreadySent;
      rethrow;
    }
  }
}

final reportRepositoryProvider = Provider<ReportRepository>((ref) {
  return ReportRepository(ref.watch(supabaseClientProvider));
});
