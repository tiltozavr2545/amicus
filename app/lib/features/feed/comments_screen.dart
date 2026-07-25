import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../auth/auth_providers.dart';
import 'comment_thread.dart';
import 'feed_repository.dart';

class CommentsScreen extends ConsumerStatefulWidget {
  const CommentsScreen({super.key, required this.postId});

  final String postId;

  @override
  ConsumerState<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends ConsumerState<CommentsScreen> {
  final _textController = TextEditingController();
  List<ThreadedComment>? _comments;
  String? _errorMessage;
  bool _isSending = false;

  /// The comment being answered, or null when writing a root comment. Nesting
  /// is one level deep, so the reply is filed under this comment's root while
  /// the comment itself is only recorded as the addressee.
  ThreadedComment? _replyTarget;

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
      if (!mounted) return;
      setState(() => _comments = threadComments(comments));
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _errorMessage = AppLocalizations.of(
          context,
        )!.failedToLoadCommentsError,
      );
    }
  }

  Future<void> _deleteComment(String commentId) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteCommentTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.deleteButton),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(feedRepositoryProvider).deleteComment(commentId);
      if (!mounted) return;
      // Deleting a comment that has replies tombstones it rather than removing
      // it, and cancels a reply in progress addressed to it, so the list is
      // re-read instead of patched locally.
      if (_replyTarget?.comment.id == commentId) {
        setState(() => _replyTarget = null);
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.failedToDeleteCommentError)),
        );
      }
    }
  }

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final target = _replyTarget;
    setState(() => _isSending = true);
    try {
      final userId = ref.read(supabaseClientProvider).auth.currentUser!.id;
      await ref
          .read(feedRepositoryProvider)
          .addComment(
            postId: widget.postId,
            authorId: userId,
            text: text,
            parentCommentId: target == null
                ? null
                : target.comment.parentCommentId ?? target.comment.id,
            replyToId: target?.comment.id,
          );
      _textController.clear();
      if (mounted) setState(() => _replyTarget = null);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _errorMessage = AppLocalizations.of(
          context,
        )!.failedToSendCommentError,
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.commentsTitle)),
      body: Column(
        children: [
          Expanded(
            child: _comments == null
                ? _errorMessage != null
                      ? Center(child: Text(_errorMessage!))
                      : const Center(child: CircularProgressIndicator())
                : _comments!.isEmpty
                ? Center(child: Text(l10n.noCommentsYetMessage))
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _comments!.length,
                    itemBuilder: (context, index) =>
                        _buildComment(l10n, _comments![index]),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_replyTarget != null) _buildReplyBanner(l10n),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          maxLength: 5000,
                          decoration: InputDecoration(
                            hintText: _replyTarget == null
                                ? l10n.writeCommentHint
                                : l10n.writeReplyHint,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: _isSending
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send),
                        onPressed: _isSending ? null : _send,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyBanner(AppLocalizations l10n) {
    return Row(
      children: [
        Expanded(
          child: Text(
            l10n.replyingToLabel(_replyTarget!.comment.authorName),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close),
          iconSize: 18,
          tooltip: l10n.cancelReplyTooltip,
          onPressed: () => setState(() => _replyTarget = null),
        ),
      ],
    );
  }

  Widget _buildComment(AppLocalizations l10n, ThreadedComment threaded) {
    final comment = threaded.comment;
    final currentUserId = ref.read(supabaseClientProvider).auth.currentUser!.id;
    final isOwnComment = comment.authorId == currentUserId;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: threaded.isReply ? 32 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(comment.authorName, style: textTheme.titleSmall),
                if (threaded.replyToName != null)
                  Text(
                    l10n.inReplyToLabel(threaded.replyToName!),
                    style: textTheme.bodySmall,
                  ),
                if (comment.isDeleted)
                  Text(
                    l10n.deletedCommentPlaceholder,
                    style: textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: Theme.of(context).disabledColor,
                    ),
                  )
                else
                  Text(comment.text),
                Text(
                  DateFormat(
                    'd MMM y, HH:mm',
                    l10n.localeName,
                  ).format(comment.createdAt),
                  style: textTheme.bodySmall,
                ),
              ],
            ),
          ),
          // A tombstone offers neither action: there is nothing left to delete,
          // and the server rejects replies to it.
          if (!comment.isDeleted)
            TextButton(
              onPressed: () => setState(() => _replyTarget = threaded),
              child: Text(l10n.replyButton),
            ),
          if (isOwnComment && !comment.isDeleted)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              iconSize: 20,
              onPressed: () => _deleteComment(comment.id),
            ),
        ],
      ),
    );
  }
}
