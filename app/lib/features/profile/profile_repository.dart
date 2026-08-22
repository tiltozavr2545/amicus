import 'dart:async';
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

/// One photo in a user's profile gallery (up to 80 — see
/// `profile_photos` in the migration). [position] orders the gallery; the
/// lowest [position] is what `users.avatar_path` mirrors (kept in sync by a
/// DB trigger), so it's also what every other screen's small avatar shows.
class ProfilePhoto {
  const ProfilePhoto({
    required this.id,
    required this.position,
    required this.storagePath,
  });

  final String id;
  final int position;
  final String storagePath;

  factory ProfilePhoto.fromRow(Map<String, dynamic> row) => ProfilePhoto(
    id: row['id'] as String,
    position: (row['position'] as num).toInt(),
    storagePath: row['storage_path'] as String,
  );
}

/// One picked-but-not-yet-uploaded profile photo, held by the profile
/// screen's local state while [ProfileRepository.addPhotos] uploads it.
class PendingPhoto {
  const PendingPhoto({
    required this.photoClientToken,
    required this.bytes,
    required this.ext,
  });

  final String photoClientToken;
  final Uint8List bytes;
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

  /// Uploads [items] and appends them to the end of the gallery, after
  /// whatever [existing] photos are already there. `users.avatar_path` is
  /// updated automatically by a DB trigger, not here — see
  /// `sync_avatar_path_from_profile_photos()` in the migration.
  ///
  /// Uploads go through [uploadTolerant] for the same reason post media does:
  /// `.timeout()` stops waiting without cancelling, so a batch can be half
  /// landed when the screen reports failure, and the natural retry re-sends
  /// items whose objects are already there. A plain `uploadBinary` answers
  /// that with 409 and failed the whole batch every single time, forever.
  Future<void> addPhotos({
    required String userId,
    required List<PendingPhoto> items,
    required List<ProfilePhoto> existing,
  }) async {
    if (items.isEmpty) return;
    for (final item in items) {
      await uploadTolerant(
        _client,
        bucket: mediaBucket,
        path: profilePhotoPath(
          userId: userId,
          photoClientToken: item.photoClientToken,
          ext: item.ext,
        ),
        bytes: item.bytes,
      );
    }
    final nextPosition = existing.isEmpty
        ? 0
        : existing.map((p) => p.position).reduce((a, b) => a > b ? a : b) + 1;
    final rows = [
      for (var i = 0; i < items.length; i++)
        {
          'user_id': userId,
          'position': nextPosition + i,
          'storage_path': profilePhotoPath(
            userId: userId,
            photoClientToken: items[i].photoClientToken,
            ext: items[i].ext,
          ),
        },
    ];
    await _client
        .from('profile_photos')
        .upsert(
          rows,
          onConflict: 'user_id,storage_path',
          ignoreDuplicates: true,
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
