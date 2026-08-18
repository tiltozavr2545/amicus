import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/file_extension.dart';
import '../../theme/theme_toggle_switch.dart';
import '../auth/auth_providers.dart';
import '../feed/post_list_view.dart';
import '../notifications/push_notifications_repository.dart';
import '../settings/settings_button.dart';
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

  /// Shared error feedback for every write path on this screen. Takes a
  /// message *builder*, not a resolved string: after an `await`, the
  /// `AppLocalizations.of(context)` lookup itself is only safe once
  /// `context.mounted` has been checked, so it has to happen in here too —
  /// resolving the string at the call site (before this runs) would read
  /// context that may already be gone.
  void _showError(
    BuildContext context,
    String Function(AppLocalizations) message,
  ) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message(AppLocalizations.of(context)!))),
    );
  }

  Future<void> _saveName(String userId) async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showError(context, (l10n) => l10n.nameRequiredError);
      return;
    }
    setState(() => _isSaving = true);
    try {
      await ref
          .read(profileRepositoryProvider)
          .updateName(userId: userId, name: name);
      ref.invalidate(_profileProvider);
    } catch (e) {
      // _showError checks context.mounted itself before touching context —
      // the analyzer can't see across that call, only into this function.
      // ignore: use_build_context_synchronously
      _showError(context, (l10n) => l10n.failedToSaveNameError);
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
      final ext = fileExtension(picked.name);
      await ref
          .read(profileRepositoryProvider)
          .uploadAvatar(userId: userId, bytes: bytes, fileExt: ext);
      ref.invalidate(_profileProvider);
    } catch (e) {
      // ignore: use_build_context_synchronously
      _showError(context, (l10n) => l10n.failedToUploadAvatarError);
    } finally {
      if (mounted) setState(() => _isUploadingAvatar = false);
    }
  }

  /// Drops this device's push token for the current user before signing out
  /// — while the session is still valid, since the delete is RLS-gated on
  /// `auth.uid()` — so a different user signing in on the same device
  /// afterward doesn't keep receiving pushes meant for whoever just left.
  Future<void> _signOut(BuildContext context) async {
    final userId = ref.read(currentUserIdProvider);
    if (userId != null) {
      try {
        await ref
            .read(pushNotificationsRepositoryProvider)
            .unregisterDevice(userId: userId);
      } catch (_) {
        // Best-effort: a network hiccup here shouldn't block sign-out.
      }
    }
    try {
      await ref.read(supabaseClientProvider).auth.signOut();
    } catch (e) {
      // ignore: use_build_context_synchronously
      _showError(context, (l10n) => l10n.unexpectedError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = ref.watch(currentUserIdProvider);
    final profileAsync = ref.watch(_profileProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.profileTitle),
        actions: [
          const SettingsButton(),
          const ThemeToggleSwitch(),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: l10n.signOutTooltip,
            onPressed: () => _signOut(context),
          ),
        ],
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) =>
            Center(child: Text(l10n.failedToLoadProfileError)),
        data: (profile) {
          if (_nameController.text.isEmpty) {
            _nameController.text = profile.name;
          }
          final avatarBytes = profile.avatarPath == null
              ? null
              : ref.watch(avatarBytesProvider(profile.avatarPath!)).value;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
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
                      decoration: InputDecoration(labelText: l10n.nameLabel),
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
                          : Text(l10n.saveButton),
                    ),
                  ],
                ),
              ),
              const Divider(height: 32),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.myPostsTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              Expanded(
                child: PostListView(
                  authorId: userId,
                  emptyState: (context) => Text(l10n.noOwnPostsYetMessage),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
