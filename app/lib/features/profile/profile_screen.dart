import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../auth/auth_providers.dart';
import 'profile_repository.dart';

final _profileProvider = FutureProvider.autoDispose<Profile>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  return ref.watch(profileRepositoryProvider).fetchProfile(userId!);
});

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _nameController = TextEditingController();
  bool _isSaving = false;
  bool _isUploadingAvatar = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveName(String userId) async {
    setState(() => _isSaving = true);
    try {
      await ref
          .read(profileRepositoryProvider)
          .updateName(userId: userId, name: _nameController.text.trim());
      ref.invalidate(_profileProvider);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _pickAndUploadAvatar(String userId) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
    );
    if (picked == null) return;

    setState(() => _isUploadingAvatar = true);
    try {
      final bytes = await picked.readAsBytes();
      final ext = picked.name.split('.').last;
      await ref
          .read(profileRepositoryProvider)
          .uploadAvatar(userId: userId, bytes: bytes, fileExt: ext);
      ref.invalidate(_profileProvider);
    } finally {
      if (mounted) setState(() => _isUploadingAvatar = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = ref.watch(currentUserIdProvider);
    final profileAsync = ref.watch(_profileProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Профиль'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Выйти',
            onPressed: () => ref.read(supabaseClientProvider).auth.signOut(),
          ),
        ],
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) =>
            Center(child: Text('Ошибка загрузки профиля: $error')),
        data: (profile) {
          if (_nameController.text.isEmpty) {
            _nameController.text = profile.name;
          }
          final avatarBytes = profile.avatarPath == null
              ? null
              : ref.watch(avatarBytesProvider(profile.avatarPath!)).value;
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                GestureDetector(
                  onTap: _isUploadingAvatar
                      ? null
                      : () => _pickAndUploadAvatar(userId!),
                  child: CircleAvatar(
                    radius: 48,
                    backgroundImage: avatarBytes != null
                        ? MemoryImage(avatarBytes)
                        : null,
                    child: _isUploadingAvatar
                        ? const CircularProgressIndicator()
                        : avatarBytes == null
                        ? const Icon(Icons.camera_alt, size: 32)
                        : null,
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Имя'),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _isSaving ? null : () => _saveName(userId!),
                  child: _isSaving
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Сохранить'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
