import 'package:flutter_test/flutter_test.dart';

import 'package:amicus/features/notifications/push_deep_link.dart';

void main() {
  group('pushTargetFrom', () {
    test('a room message opens that room chat', () {
      final target = pushTargetFrom({
        'kind': 'room_message',
        'room_id': 'room-1',
        'author_name': 'Аня',
      });

      expect(target, isA<RoomChatTarget>());
      expect((target! as RoomChatTarget).roomId, 'room-1');
    });

    test('a comment and a reply both open the post they are under', () {
      for (final kind in ['post_comment', 'comment_reply']) {
        final target = pushTargetFrom({'kind': kind, 'post_id': 'post-1'});
        expect(target, isA<PostCommentsTarget>(), reason: kind);
        expect((target! as PostCommentsTarget).postId, 'post-1', reason: kind);
      }
    });

    test('the feed answers everything that is only "something is new"', () {
      for (final kind in ['new_post', 'digest', 'inactive_week']) {
        expect(pushTargetFrom({'kind': kind}), isA<FeedTarget>(), reason: kind);
      }
    });

    test('an update notice has nowhere to take anyone', () {
      // The app is not where one updates it.
      expect(pushTargetFrom({'kind': 'app_update'}), isNull);
      expect(pushTargetFrom({'kind': 'app_update_important'}), isNull);
    });

    test('a kind this app has never heard of is not a destination', () {
      // A migration can add a kind before this table hears about it; opening
      // the app is all such a push ever asked for.
      expect(pushTargetFrom({'kind': 'something_new'}), isNull);
      expect(pushTargetFrom(const {}), isNull);
    });

    test('an id-less push of an id-carrying kind is not a destination', () {
      // Rather than opening an empty screen: `data` comes off the wire, and
      // half of it arriving is exactly the case a cast would crash on.
      expect(pushTargetFrom({'kind': 'room_message'}), isNull);
      expect(pushTargetFrom({'kind': 'post_comment'}), isNull);
    });
  });
}
