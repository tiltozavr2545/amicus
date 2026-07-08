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

  Future<void> createProfile({
    required String userId,
    required String name,
  }) async {
    await _client.from('users').insert({
      'id': userId,
      'name': name.isEmpty ? 'Без имени' : name,
    });
  }

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
  Future<String> uploadAvatar({
    required String userId,
    required Uint8List bytes,
    required String fileExt,
  }) async {
    final path = 'avatars/$userId/avatar.$fileExt';
    await _client.storage
        .from(_bucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(upsert: true),
        );
    await _client.from('users').update({'avatar_path': path}).eq('id', userId);
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
