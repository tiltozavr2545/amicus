import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

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

  /// Set only when the list itself could not be loaded — it is rendered *in
  /// place of* the list, so it can say nothing about a failure that happens
  /// once comments are on screen. Those report through a snackbar.
  String? _errorMessage;

  bool _isSending = false;

  /// Idempotency key for the send in flight, and the content it was minted for.
  ///
  /// Kept across retries so a resend after a timeout can't create a second
  /// comment (see [FeedRepository.addComment]), but tied to the *content* and
  /// not merely to the attempt: the server resolves a repeat token by doing
  /// nothing, so reusing one after the user edited the text or changed who the
  /// reply addresses would silently discard that edit while the screen reported
  /// success. A changed composition therefore mints a fresh token.
  String? _pendingToken;
  String? _pendingSignature;

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

  /// Returns whether the list now reflects the server.
  ///
  /// The failure branch has to pick its channel the same way [_send] does:
  /// `_errorMessage` is rendered only *in place of* the list, so once comments
  /// are on screen, assigning to it puts the message nowhere at all. A reload
  /// that failed after a successful send was therefore completely silent — the
  /// composer cleared, the comment was missing, and the user reasonably
  /// concluded it had not sent.
  Future<bool> _load() async {
    try {
      final comments = await ref
          .read(feedRepositoryProvider)
          .fetchComments(widget.postId);
      if (!mounted) return false;
      setState(() {
        _comments = threadComments(comments);
        _errorMessage = null;
      });
      return true;
    } catch (e) {
      if (!mounted) return false;
      final message = AppLocalizations.of(context)!.failedToLoadCommentsError;
      if (_comments == null) {
        setState(() => _errorMessage = message);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      return false;
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

    final l10n = AppLocalizations.of(context)!;
    final target = _replyTarget;
    setState(() => _isSending = true);
    try {
      // Not `!`: the session can clear while this screen is still mounted.
      final userId = ref.read(currentUserIdProvider);
      if (userId == null) return;
      final parentCommentId = target == null
          ? null
          : target.comment.parentCommentId ?? target.comment.id;
      final replyToId = target?.comment.id;
      // Free-form text goes last: the two ids ahead of it are either a uuid
      // or the literal "null", neither of which can contain the separator,
      // so no other composition joins to the same signature.
      final signature = '$parentCommentId|$replyToId|$text';
      if (_pendingSignature != signature) {
        _pendingToken = const Uuid().v4();
        _pendingSignature = signature;
      }
      await ref
          .read(feedRepositoryProvider)
          .addComment(
            clientToken: _pendingToken!,
            postId: widget.postId,
            authorId: userId,
            text: text,
            parentCommentId: parentCommentId,
            replyToId: replyToId,
          );
      _textController.clear();
      if (mounted) setState(() => _replyTarget = null);
      // The token is retired only once the reload has confirmed the comment
      // landed. Clearing it right after the insert defeated the whole
      // idempotency scheme on the one path that needs it: send succeeds,
      // reload fails, the user retypes the identical text — and with the token
      // already gone, `_pendingSignature != signature` minted a fresh one, so
      // `onConflict: 'author_id,client_token'` matched nothing and the comment
      // was inserted a second time. Keeping it means that retry reuses the same
      // token and the server no-ops it.
      if (await _load()) {
        _pendingToken = null;
        _pendingSignature = null;
      }
    } catch (e) {
      // A snackbar, not _errorMessage: that field is rendered only in place of
      // the list, so once comments have loaded — which is the normal state when
      // sending — assigning to it puts the message nowhere. The composer would
      // just stop, and the server rejects a reply for several ordinary reasons
      // (its target was deleted or blocked while the reply was being typed).
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.failedToSendCommentError)));
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
    final currentUserId = ref.read(currentUserIdProvider);
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
