import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/delete_order.dart';
import '../../shared/media_bucket.dart';
import '../../shared/network_timeout.dart';
import '../../shared/tolerant_upload.dart';
import '../auth/auth_providers.dart';

class Profile {
  const Profile({required this.id, required this.name, this.avatarPath});

  final String id;
  final String name;
  final String? avatarPath;

  factory Profile.fromRow(Map<String, dynamic> row) {
    return Profile(
      id: row['id'] as String,
      name: row['name'] as String,
      avatarPath: row['avatar_path'] as String?,
    );
  }
}

/// One photo in a user's profile gallery (up to 80 — see `profile_photos` in
/// the migration).
///
/// Display order is `profile_photos.position`, and it stays there: the server
/// hands rows back already ordered ([ProfileRepository.fetchPhotos]) and
/// assigns the numbers itself on append (`append_profile_photos()`,
/// 20260824130000) and on reorder (`reorder_profile_photos()`, which takes
/// ids, not positions). A `position` field here carried nothing anyone read
/// and invited the next reader to believe the order was the client's to
/// decide — which is exactly the mistake 20260824130000 was written to undo.
/// The lowest position is what `users.avatar_path` mirrors, kept in sync by a
/// DB trigger, so it is also what every other screen's small avatar shows.
class ProfilePhoto {
  const ProfilePhoto({required this.id, required this.storagePath});

  final String id;
  final String storagePath;

  factory ProfilePhoto.fromRow(Map<String, dynamic> row) => ProfilePhoto(
    id: row['id'] as String,
    storagePath: row['storage_path'] as String,
  );
}

/// One picked-but-not-yet-uploaded profile photo, held by the profile
/// screen's local state while [ProfileRepository.addPhotos] uploads it.
///
/// Carries the picked file's *path*, not its bytes — the same choice
/// `MediaFile` makes for video in the composer, and for the same reason. A
/// batch here can be up to 80 photos, the screen paints none of them before
/// they are uploaded, and [ProfileRepository.addPhotos] sends them one at a
/// time. Holding bytes meant every slot was read at pick time and kept
/// resident for the whole upload — 80 files at `maxWidth: 1600` is tens to
/// well over a hundred megabytes standing in memory during a sequential
/// upload that takes minutes on a mobile uplink, on top of the copy
/// `MultipartFile.fromBytes` makes for the file actually in flight. It bounds
/// concurrent residency, not the read itself: each file is still fully read
/// when its turn comes (see [uploadTolerantFile]), then released.
class PendingPhoto {
  const PendingPhoto({
    required this.photoClientToken,
    required this.path,
    required this.ext,
  });

  final String photoClientToken;

  /// Where the picked file sits on disk until its turn to upload comes.
  final String path;

  final String ext;
}

/// Storage path for one profile photo. Reuses the `avatars/<uid>/…` prefix
/// the existing avatar storage policies already scope SELECT/INSERT/
/// UPDATE/DELETE to (20260707222025), so adding the gallery needed no new
/// storage policy. [photoClientToken] is minted per photo at pick time, not
/// per upload attempt — a retry addresses the same object instead of leaking
/// a duplicate into the bucket, same reasoning as [postMediaPath].
String profilePhotoPath({
  required String userId,
  required String photoClientToken,
  required String ext,
}) => 'avatars/$userId/$photoClientToken.$ext';

class ProfileRepository {
  ProfileRepository(this._client);

  final SupabaseClient _client;

  Future<Profile> fetchProfile(String userId) async {
    final row = await _client
        .from('users')
        .select()
        .eq('id', userId)
        .single()
        .timeout(networkTimeout);
    return Profile.fromRow(row);
  }

  Future<void> updateName({
    required String userId,
    required String name,
  }) async {
    await _client
        .from('users')
        .update({'name': name})
        .eq('id', userId)
        .timeout(networkTimeout);
  }

  /// Fetches a user's profile photo gallery, ordered for display.
  Future<List<ProfilePhoto>> fetchPhotos(String userId) async {
    final rows = await _client
        .from('profile_photos')
        .select()
        .eq('user_id', userId)
        .order('position', ascending: true)
        .timeout(networkTimeout);
    return rows.map(ProfilePhoto.fromRow).toList();
  }

  /// Uploads [items] and appends them to the end of the gallery.
  /// `users.avatar_path` is updated automatically by a DB trigger, not here —
  /// see `sync_avatar_path_from_profile_photos()` in the migration.
  ///
  /// Uploads go through [uploadTolerantFile] for the same reason post media
  /// does:
  /// `.timeout()` stops waiting without cancelling, so a batch can be half
  /// landed when the screen reports failure, and the natural retry re-sends
  /// items whose objects are already there. A plain `uploadBinary` answers
  /// that with 409 and failed the whole batch every single time, forever.
  ///
  /// The rows go through `append_profile_photos()` rather than a direct
  /// upsert, and the caller no longer passes the gallery in. `position` used
  /// to be computed here, from the screen's cached list — which is stale in
  /// exactly the situations the retry tolerance above exists for. A previous
  /// batch that committed after this method reported failure (or a second
  /// device) leaves that list short, the new rows aim at positions that are
  /// already taken, and `profile_photos_user_position_key` rejects them. The
  /// upsert cannot absorb that: it arbitrates on `(user_id, storage_path)`,
  /// and a fresh file has a path of its own, so the position clash is a hard
  /// error that takes the whole batch with it. The server assigns positions
  /// from the table it is inserting into, in the same transaction, so a stale
  /// client has nothing to be stale about — the same move migration
  /// 20260820150000 made for reordering.
  Future<void> addPhotos({
    required String userId,
    required List<PendingPhoto> items,
  }) async {
    if (items.isEmpty) return;
    for (final item in items) {
      await uploadTolerantFile(
        _client,
        bucket: mediaBucket,
        path: profilePhotoPath(
          userId: userId,
          photoClientToken: item.photoClientToken,
          ext: item.ext,
        ),
        file: File(item.path),
      );
    }
    await _client
        .rpc(
          'append_profile_photos',
          params: {
            'p_items': [
              for (final item in items)
                {
                  'storage_path': profilePhotoPath(
                    userId: userId,
                    photoClientToken: item.photoClientToken,
                    ext: item.ext,
                  ),
                },
            ],
          },
        )
        .timeout(networkTimeout);
  }

  /// Applies a new display order for the whole gallery, in one transaction.
  ///
  /// Still delete+insert rather than update-in-place — `profile_photos` has
  /// no UPDATE policy on purpose — but both halves now happen inside
  /// `reorder_profile_photos()`, server-side. As two PostgREST calls they
  /// were two transactions with nothing in between, and a failure after the
  /// DELETE (which `.timeout()` makes routine: it stops waiting without
  /// cancelling) wiped the entire gallery — including `users.avatar_path`,
  /// which the sync trigger had already recomputed against zero rows, so the
  /// user's avatar vanished everywhere at once while their files sat on in
  /// Storage referenced by nothing.
  ///
  /// The whole gallery has to be passed, not a slice: positions are rewritten
  /// as a dense 0..N-1 and a partial reorder would collide with the rows left
  /// out. The server rejects a mismatched set with `PT422`.
  Future<void> reorderPhotos({required List<ProfilePhoto> order}) async {
    if (order.isEmpty) return;
    await _client
        .rpc(
          'reorder_profile_photos',
          params: {'p_photo_ids': order.map((p) => p.id).toList()},
        )
        .timeout(networkTimeout);
  }

  /// Removes [photos] from the gallery: their rows, then their storage
  /// objects. `users.avatar_path` is re-synced automatically by the same DB
  /// trigger that handles [addPhotos]/[reorderPhotos].
  ///
  /// Ordering — and the reason for it — lives in [deleteRowsThenObjects].
  /// It bites hardest here: deleting the object for position 0 first meant the
  /// sync trigger never ran, so `users.avatar_path` went on naming bytes that
  /// were gone and the avatar turned into a grey placeholder in the user's own
  /// profile, in every friend's Connections list and on all of their posts.
  Future<void> deletePhotos({required List<ProfilePhoto> photos}) {
    if (photos.isEmpty) return Future.value();
    return deleteRowsThenObjects(
      rows: () => _client
          .from('profile_photos')
          .delete()
          .inFilter('id', photos.map((p) => p.id).toList())
          .timeout(networkTimeout),
      objects: () => _client.storage
          .from(mediaBucket)
          .remove(photos.map((p) => p.storagePath).toList())
          .timeout(networkTimeout),
    );
  }

  /// The `media` bucket is private (RLS-controlled); the SDK's storage
  /// client automatically attaches the current user's access token, so a
  /// plain SDK download respects the same policies as any other request.
  Future<Uint8List> downloadAvatar(String path) {
    return _client.storage
        .from(mediaBucket)
        .download(path)
        .timeout(networkTimeout);
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref.watch(supabaseClientProvider));
});

/// The signed-in user's own profile — shared by the profile screen and the
/// shell's bottom bar (which paints the "profile" tab with this avatar
/// instead of a generic icon), so both read the same fetch/cache instead of
/// each racing its own.
final myProfileProvider = FutureProvider.autoDispose<Profile>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  return ref.watch(profileRepositoryProvider).fetchProfile(userId!);
});

/// How long a fetched image stays cached after the last widget stops watching
/// it. Long enough to cover the round trip this cache exists for — leave a
/// screen, come back, don't re-download — and short enough that a gallery the
/// user has walked away from doesn't sit in memory for the rest of the day.
const _avatarCacheGrace = Duration(minutes: 5);

/// Downloads avatar bytes for any storage path, keyed by path so callers
/// (own profile, friends list, ...) share the same cached result.
///
/// The successful result outlives its listeners so revisiting a screen doesn't
/// re-download unchanged avatars. This is safe because every profile photo is
/// uploaded under its own client-minted path (see [profilePhotoPath]), so a
/// changed photo is a different cache key rather than a stale hit. Errors are
/// not kept alive, so they retry naturally.
///
/// The keep-alive is released [_avatarCacheGrace] after the last listener goes
/// away, rather than held for the process's whole life. A bare `keepAlive()`
/// pins every path ever fetched: the small set of avatars the lists reuse is
/// what it was written for, but whole galleries flow through the same family —
/// opening the delete or reorder screen on a full 80-photo profile pins 80
/// `maxWidth: 1600` JPEGs, and nothing ever let go of them. It also meant the
/// previous account's photos stayed resident across a sign-out, which is the
/// in-memory shape of what [FeedCache]'s per-user keys close on disk.
final avatarBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, path) async {
      final bytes = await ref
          .watch(profileRepositoryProvider)
          .downloadAvatar(path);
      final link = ref.keepAlive();
      Timer? release;
      // onCancel/onResume, not onDispose alone: the provider is "cancelled"
      // when its last listener leaves and "resumed" if one comes back before
      // the timer fires, which is exactly the revisit this cache is for.
      ref.onCancel(() => release = Timer(_avatarCacheGrace, link.close));
      ref.onResume(() => release?.cancel());
      ref.onDispose(() => release?.cancel());
      return bytes;
    });
