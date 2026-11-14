import 'dart:io';
import 'dart:typed_data';

import 'package:amicus/features/feed/feed_repository.dart';
import 'package:amicus/features/feed/post_draft_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late PostDraftStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('amicus-draft-test-');
    store = PostDraftStore(directory: () async => root);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  PostDraft draft({
    String text = 'Story',
    List<PendingMedia> media = const [],
  }) => PostDraft(
    token: 'submission-token',
    text: text,
    visibility: PostVisibility.favorites,
    media: media,
  );

  test(
    'A fresh store restores copied videos, images, order, audience and retry token',
    () async {
      final video = File('${root.path}/picker.mp4');
      await video.writeAsBytes([7, 8, 9]);
      await store.save(
        'alice',
        draft(
          media: [
            PendingMedia(
              mediaClientToken: 'video',
              mediaType: MediaType.video,
              source: MediaFile(video.path),
              ext: 'mp4',
              posterBytes: Uint8List.fromList([4, 5]),
            ),
            PendingMedia(
              mediaClientToken: 'photo',
              mediaType: MediaType.image,
              source: MediaBytes(Uint8List.fromList([1, 2, 3])),
              ext: 'jpg',
            ),
          ],
        ),
      );
      await video.delete();
      final restored = (await PostDraftStore(
        directory: () async => root,
      ).load('alice'))!;
      expect(restored.token, 'submission-token');
      expect(restored.text, 'Story');
      expect(restored.visibility, PostVisibility.favorites);
      expect(restored.media.map((m) => m.mediaClientToken), ['video', 'photo']);
      expect(
        await File(
          (restored.media.first.source as MediaFile).path,
        ).readAsBytes(),
        [7, 8, 9],
      );
      expect(restored.media.first.posterBytes, [4, 5]);
      expect((restored.media.last.source as MediaBytes).bytes, [1, 2, 3]);
      expect(await store.load('bob'), isNull);
    },
  );

  test(
    'Queued writes preserve the latest text and clearing follows pending writes',
    () async {
      await Future.wait([
        store.save('alice', draft(text: 'First')),
        store.save('alice', draft(text: 'Last')),
      ]);
      expect((await store.load('alice'))!.text, 'Last');
      await Future.wait([store.save('alice', draft()), store.clear('alice')]);
      expect(await store.load('alice'), isNull);
    },
  );

  test(
    'Removing an attachment deletes its private copy and an empty draft clears everything',
    () async {
      await store.save(
        'alice',
        draft(
          media: [
            PendingMedia(
              mediaClientToken: 'photo',
              mediaType: MediaType.image,
              source: MediaBytes(Uint8List.fromList([1])),
              ext: 'jpg',
            ),
          ],
        ),
      );
      await store.save('alice', draft());
      expect(
        File('${root.path}/post_drafts/alice/photo.jpg').existsSync(),
        false,
      );
      await store.save('alice', draft(text: ''));
      expect(Directory('${root.path}/post_drafts/alice').existsSync(), false);
    },
  );
}
