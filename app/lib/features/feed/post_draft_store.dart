import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'feed_repository.dart';

class PostDraft {
  const PostDraft({
    required this.token,
    required this.text,
    required this.visibility,
    required this.media,
  });
  final String token;
  final String text;
  final PostVisibility visibility;
  final List<PendingMedia> media;
}

/// Account-scoped local drafts. Media are copied out of the picker's temporary
/// directory; the metadata rename commits a complete snapshot after its files.
class PostDraftStore {
  PostDraftStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _pending = Future.value();

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _pending.then((_) => work());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<Directory> _folder(String user) async => Directory(
    '${(await _directory()).path}/post_drafts/${Uri.encodeComponent(user)}',
  );

  Future<PostDraft?> load(String user) => _serial(() async {
    final folder = await _folder(user);
    final file = File('${folder.path}/draft.json');
    if (!file.existsSync()) return null;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final media = <PendingMedia>[];
    for (final raw in data['media'] as List<dynamic>) {
      final item = raw as Map<String, dynamic>;
      final token = item['token'] as String;
      final ext = item['ext'] as String;
      final video = item['video'] as bool;
      final source = File('${folder.path}/$token.$ext');
      media.add(
        PendingMedia(
          mediaClientToken: token,
          mediaType: video ? MediaType.video : MediaType.image,
          source: video
              ? MediaFile(source.path)
              : MediaBytes(await source.readAsBytes()),
          ext: ext,
          posterBytes: video
              ? await File('${folder.path}/$token.poster').readAsBytes()
              : null,
        ),
      );
    }
    return PostDraft(
      token: data['token'] as String,
      text: data['text'] as String,
      visibility: PostVisibility.fromDb(data['visibility'] as String),
      media: media,
    );
  });

  Future<void> save(String user, PostDraft draft) => _serial(() async {
    final folder = await _folder(user);
    if (draft.text.isEmpty && draft.media.isEmpty) {
      if (folder.existsSync()) await folder.delete(recursive: true);
      return;
    }
    await folder.create(recursive: true);
    final retained = <String>{'draft.json'};
    for (final item in draft.media) {
      final name = '${item.mediaClientToken}.${item.ext}';
      retained.add(name);
      final target = File('${folder.path}/$name');
      if (!target.existsSync()) {
        final staging = File('${target.path}.tmp');
        switch (item.source) {
          case MediaBytes(:final bytes):
            await staging.writeAsBytes(bytes, flush: true);
          case MediaFile(:final path):
            await File(path).copy(staging.path);
        }
        await staging.rename(target.path);
      }
      if (item.posterBytes case final bytes?) {
        final name = '${item.mediaClientToken}.poster';
        retained.add(name);
        final poster = File('${folder.path}/$name');
        if (!poster.existsSync()) {
          await poster.writeAsBytes(bytes, flush: true);
        }
      }
    }
    final temporary = File('${folder.path}/draft.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'token': draft.token,
        'text': draft.text,
        'visibility': draft.visibility.dbValue,
        'media': [
          for (final item in draft.media)
            {
              'token': item.mediaClientToken,
              'ext': item.ext,
              'video': item.mediaType == MediaType.video,
            },
        ],
      }),
      flush: true,
    );
    await temporary.rename('${folder.path}/draft.json');
    await for (final file in folder.list()) {
      if (file is File && !retained.contains(file.uri.pathSegments.last)) {
        await file.delete();
      }
    }
  });

  Future<void> clear(String user) => _serial(() async {
    final folder = await _folder(user);
    if (folder.existsSync()) await folder.delete(recursive: true);
  });
}

final postDraftStoreProvider = Provider<PostDraftStore>(
  (ref) => PostDraftStore(),
);
