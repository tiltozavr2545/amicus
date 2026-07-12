import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

const _bucket = 'media';

class ProfileRepository {
  ProfileRepository(this._client);

  final SupabaseClient _client;

  Future<Profile> fetchProfile(String userId) async {
    final row = await _client.from('users').select().eq('id', userId).single();
    return Profile.fromRow(row);
  }

  Future<void> updateName({
    required String userId,
    required String name,
  }) async {
    await _client.from('users').update({'name': name}).eq('id', userId);
  }

  /// Uploads [bytes] as the user's avatar and returns the new storage path.
  ///
  /// The filename carries a timestamp so every upload writes to a *new* path.
  /// That makes the path itself a version key: a re-uploaded photo produces a
  /// different `avatar_path`, so [avatarBytesProvider] (keyed by path) can be
  /// kept alive across navigation without ever serving a stale image. The
  /// previous file is removed best-effort to avoid orphaned objects.
  Future<String> uploadAvatar({
    required String userId,
    required Uint8List bytes,
    required String fileExt,
  }) async {
    final existing = await _client
        .from('users')
        .select('avatar_path')
        .eq('id', userId)
        .single();
    final previousPath = existing['avatar_path'] as String?;

    final path =
        'avatars/$userId/avatar_${DateTime.now().millisecondsSinceEpoch}.$fileExt';
    await _client.storage.from(_bucket).uploadBinary(path, bytes);
    await _client.from('users').update({'avatar_path': path}).eq('id', userId);

    if (previousPath != null && previousPath != path) {
      try {
        await _client.storage.from(_bucket).remove([previousPath]);
      } catch (_) {
        // Best-effort cleanup; a leftover old avatar file is harmless.
      }
    }
    return path;
  }

  /// The `media` bucket is private (RLS-controlled); the SDK's storage
  /// client automatically attaches the current user's access token, so a
  /// plain SDK download respects the same policies as any other request.
  Future<Uint8List> downloadAvatar(String path) {
    return _client.storage.from(_bucket).download(path);
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref.watch(supabaseClientProvider));
});

/// Downloads avatar bytes for any storage path, keyed by path so callers
/// (own profile, friends list, ...) share the same cached result.
///
/// The successful result is kept alive across navigation so revisiting a screen
/// doesn't re-download unchanged avatars. This is safe because [uploadAvatar]
/// writes a fresh path per upload, so a changed photo is a different cache key
/// rather than a stale hit. Errors are not kept alive, so they retry naturally.
final avatarBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, path) async {
      final bytes = await ref
          .watch(profileRepositoryProvider)
          .downloadAvatar(path);
      ref.keepAlive();
      return bytes;
    });
