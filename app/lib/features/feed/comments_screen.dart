import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../auth/auth_providers.dart';
import 'feed_repository.dart';

class CommentsScreen extends ConsumerStatefulWidget {
  const CommentsScreen({super.key, required this.postId});

  final String postId;

  @override
  ConsumerState<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends ConsumerState<CommentsScreen> {
  final _textController = TextEditingController();
  List<Comment>? _comments;
  String? _errorMessage;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final comments = await ref
          .read(feedRepositoryProvider)
          .fetchComments(widget.postId);
      setState(() => _comments = comments);
    } catch (e) {
      setState(() => _errorMessage = 'Не удалось загрузить комментарии: $e');
    }
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    setState(() => _isSending = true);
    try {
      final userId = ref.read(supabaseClientProvider).auth.currentUser!.id;
      await ref
          .read(feedRepositoryProvider)
          .addComment(postId: widget.postId, authorId: userId, text: text);
      _textController.clear();
      await _load();
    } catch (e) {
      setState(() => _errorMessage = 'Не удалось отправить: $e');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Комментарии')),
      body: Column(
        children: [
          Expanded(
            child: _comments == null
                ? _errorMessage != null
                      ? Center(child: Text(_errorMessage!))
                      : const Center(child: CircularProgressIndicator())
                : _comments!.isEmpty
                ? const Center(child: Text('Пока нет комментариев'))
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _comments!.length,
                    itemBuilder: (context, index) {
                      final comment = _comments![index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              comment.authorName,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(comment.text),
                            Text(
                              DateFormat(
                                'd MMM y, HH:mm',
                              ).format(comment.createdAt),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: const InputDecoration(
                        hintText: 'Написать комментарий...',
                      ),
                    ),
                  ),
                  IconButton(
                    icon: _isSending
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    onPressed: _isSending ? null : _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
