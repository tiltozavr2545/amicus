import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/connections/connections_repository.dart';

/// One row as `fetchRequests()` selects it: the pair's ids plus the two
/// embedded `users` rows PostgREST resolves through the foreign keys.
Map<String, dynamic> _row({
  required String requesterId,
  required String recipientId,
  Map<String, dynamic>? requester,
  Map<String, dynamic>? recipient,
  String status = 'pending',
}) => {
  'id': 'request-1',
  'requester_id': requesterId,
  'recipient_id': recipientId,
  'status': status,
  'requester': requester,
  'recipient': recipient,
};

const _anya = {'name': 'Аня', 'avatar_path': 'avatars/anya/p0.jpg'};

void main() {
  group('ConnectionRequest.fromRow', () {
    test('an incoming request describes the requester', () {
      final request = ConnectionRequest.fromRow(
        _row(
          requesterId: 'anya',
          recipientId: 'me',
          requester: _anya,
          recipient: const {'name': 'Тимофей'},
        ),
        'me',
      );

      expect(request.isIncoming, isTrue);
      expect(request.isPending, isTrue);
      expect(request.otherId, 'anya');
      expect(request.otherName, 'Аня');
      expect(request.otherAvatarPath, 'avatars/anya/p0.jpg');
    });

    test('an outgoing request describes the recipient', () {
      final request = ConnectionRequest.fromRow(
        _row(
          requesterId: 'me',
          recipientId: 'anya',
          requester: const {'name': 'Тимофей'},
          recipient: _anya,
        ),
        'me',
      );

      expect(request.isIncoming, isFalse);
      expect(request.otherId, 'anya');
      expect(request.otherName, 'Аня');
    });

    test('an answered request is not pending', () {
      final request = ConnectionRequest.fromRow(
        _row(
          requesterId: 'me',
          recipientId: 'anya',
          requester: const {'name': 'Тимофей'},
          recipient: _anya,
          status: 'declined',
        ),
        'me',
      );

      expect(request.isPending, isFalse);
    });

    // The regression this file was written for. A request only ever exists
    // between people who share a room, and it is that room — not the request —
    // that makes the other side's `users` row readable. Once it is gone,
    // PostgREST resolves the embed to null while the request row lives on.
    //
    // This used to throw a _TypeError out of `fetchRequests()`, which put
    // `connectionRequestsProvider` into an error state that both screens read
    // as an empty list: every incoming request disappeared from the
    // Connections tab and stayed gone, because the row causing it never
    // expires.
    test('survives an embed RLS filtered out, keeping the row answerable', () {
      final request = ConnectionRequest.fromRow(
        _row(
          requesterId: 'anya',
          recipientId: 'me',
          requester: null,
          recipient: const {'name': 'Тимофей'},
        ),
        'me',
      );

      expect(request.otherName, isNull);
      expect(request.otherAvatarPath, isNull);
      // Everything the screens actually act on survives: which side this is,
      // whether it can still be answered, and who it is about.
      expect(request.id, 'request-1');
      expect(request.otherId, 'anya');
      expect(request.isIncoming, isTrue);
      expect(request.isPending, isTrue);
    });

    test('and the same holds for the sender\'s own copy', () {
      final request = ConnectionRequest.fromRow(
        _row(
          requesterId: 'me',
          recipientId: 'anya',
          requester: const {'name': 'Тимофей'},
          recipient: null,
          status: 'declined',
        ),
        'me',
      );

      expect(request.otherName, isNull);
      // This is the row that keeps the "ask" button away from a direction
      // `connection_requests_pair_key` will never accept twice, so losing it
      // would be worse than losing the name.
      expect(request.otherId, 'anya');
      expect(request.isIncoming, isFalse);
      expect(request.isPending, isFalse);
    });
  });
}
