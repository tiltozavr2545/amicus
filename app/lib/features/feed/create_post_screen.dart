import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/file_extension.dart';
import '../auth/auth_providers.dart';
import 'feed_repository.dart';

class CreatePostScreen extends ConsumerStatefulWidget {
  const CreatePostScreen({super.key});

  @override
  ConsumerState<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends ConsumerState<CreatePostScreen> {
  final _textController = TextEditingController();
  Uint8List? _imageBytes;
  String? _imageExt;
  bool _isPosting = false;
  String? _errorMessage;

  /// Idempotency key for the submission in flight, and the content it was
  /// minted for.
  ///
  /// Kept across retries so a resend after a timeout can't create a second post
  /// (see [FeedRepository.createPost]), but tied to the *content*: the server
  /// answers a repeat token by doing nothing, so reusing one after the user
  /// edited the text or swapped the photo would silently keep the old version
  /// while the screen closed as if the edit had been published.
  String? _pendingToken;
  String? _pendingText;
  Uint8List? _pendingImage;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() {
      _imageBytes = bytes;
      _imageExt = fileExtension(picked.name);
    });
  }

  Future<void> _submit() async {
    final text = _textController.text.trim();
    if (text.isEmpty && _imageBytes == null) {
      setState(
        () => _errorMessage = AppLocalizations.of(context)!.addTextOrPhotoError,
      );
      return;
    }

    setState(() {
      _isPosting = true;
      _errorMessage = null;
    });
    try {
      final userId = ref.read(currentUserIdProvider)!;
      // `identical` rather than `==`: _pickImage assigns a fresh Uint8List per
      // pick, and comparing megabytes of pixels on every submit would be a
      // pointless cost when the reference already answers "same photo?".
      if (_pendingToken == null ||
          _pendingText != text ||
          !identical(_pendingImage, _imageBytes)) {
        _pendingToken = const Uuid().v4();
        _pendingText = text;
        _pendingImage = _imageBytes;
      }
      await ref
          .read(feedRepositoryProvider)
          .createPost(
            clientToken: _pendingToken!,
            authorId: userId,
            text: text,
            imageBytes: _imageBytes,
            imageExt: _imageExt,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(
        () =>
            _errorMessage = AppLocalizations.of(context)!.failedToPublishError,
      );
    } finally {
      if (mounted) setState(() => _isPosting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.newPostTitle),
        actions: [
          TextButton(
            onPressed: _isPosting ? null : _submit,
            child: _isPosting
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.publishButton),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _textController,
              maxLines: 5,
              maxLength: 5000,
              decoration: InputDecoration(
                hintText: l10n.whatsNewHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_imageBytes != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  _imageBytes!,
                  height: 200,
                  fit: BoxFit.cover,
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.photo_outlined),
              label: Text(
                _imageBytes == null
                    ? l10n.addPhotoButton
                    : l10n.replacePhotoButton,
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
