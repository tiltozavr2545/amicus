import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../auth/auth_providers.dart';
import 'comment_thread.dart';
import 'feed_repository.dart';

class CommentsScreen extends ConsumerStatefulWidget {
  const CommentsScreen({super.key, required this.postId, this.onCountChanged});

  final String postId;

  /// Сообщает открывшему экрану, сколько комментариев у поста на самом деле —
  /// после каждой успешной загрузки списка, то есть и после отправки, и после
  /// удаления.
  ///
  /// Колбэк, а не возвращаемое значение маршрута: экран закрывают системной
  /// кнопкой «назад», у которой результата нет, а перехватывать её через
  /// PopScope ради счётчика — вмешательство в жест, который в этом проекте
  /// проверить нечем (см. «Грабли» в CLAUDE.md). Заодно карточка под
  /// экраном обновляется сразу, а не при выходе.
  ///
  /// Дёргать [FeedRefreshTick] здесь было бы неверно по цене: он перезагружает
  /// первую страницу КАЖДОГО открытого списка, а изменилось одно число на
  /// одной карточке.
  ///
  /// Не вызывается вовсе, когда список обрезан по [commentFetchLimit]: длина
  /// обрезанного списка — уже не «сколько их на самом деле», а потолок, и
  /// подставить её значило бы уронить счётчик на карточке с настоящего числа
  /// до 500. Карточка в этом случае остаётся с числом от `comment_summary()`,
  /// которое считает всё и на сервере.
  final ValueChanged<int>? onCountChanged;

  @override
  ConsumerState<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends ConsumerState<CommentsScreen> {
  final _textController = TextEditingController();
  List<ThreadedComment>? _comments;

  /// У поста больше комментариев, чем вернул один запрос (см.
  /// [commentFetchLimit]). Рисует сноску в конце списка и запирает
  /// [CommentsScreen.onCountChanged].
  bool _isTruncated = false;

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
      final page = await ref
          .read(feedRepositoryProvider)
          .fetchComments(widget.postId);
      if (!mounted) return false;
      setState(() {
        _comments = threadComments(page.comments);
        _isTruncated = page.isTruncated;
        _errorMessage = null;
      });
      // Из СЫРОГО списка, не из threadComments(): счётчик на карточке рисует
      // `comment_summary()`, а он считает `count(*) … where deleted_at is
      // null` — то есть ровно видимые нетомбстоненные строки. threadComments()
      // сверх этого прячет ответы без корня и заглушки без ответов, так что
      // его длина дала бы другое число.
      //
      // И только когда список пришёл целиком: у обрезанного длина — это
      // потолок, а не количество (см. [CommentsScreen.onCountChanged]).
      if (!page.isTruncated) {
        widget.onCountChanged?.call(
          page.comments.where((c) => !c.isDeleted).length,
        );
      }
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
      // Both under the same guard. The clear() used to sit above it, one line
      // too early: nothing stops the user pressing back while the send is in
      // flight, and by the time this resumes `dispose()` may already have
      // disposed the controller — writing to one throws
      // "A TextEditingController was used after being disposed" (verified: it
      // throws, it is not a no-op).
      //
      // Nothing visible came of it, and that is the whole reason it survived:
      // the throw lands in this method's own `catch`, which then returns on
      // `!mounted`, so the exception never reaches a screen or a log. What it
      // actually did was divert control — the reload below and the retiring of
      // the idempotency token were skipped, which on a screen that is already
      // gone costs nothing. It stops costing nothing the moment that `catch`
      // is narrowed to the failures it is meant for. Guarded here rather than
      // left to that.
      if (mounted) {
        _textController.clear();
        setState(() => _replyTarget = null);
      }
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
      if (!mounted) return;
      // Re-read the thread before reporting the failure. `.timeout()` stops
      // waiting without cancelling, so "failed to send" routinely means "we
      // stopped listening", not "nothing landed" — and this list is the only
      // place the user can tell the two apart. Without the reload they are
      // told it failed while their comment sits one refresh away, and the
      // natural response — retype it, a little differently — changes the
      // signature, mints a fresh `_pendingToken` and posts it a second time.
      //
      // This narrows that window; it does not close it. A resend whose text
      // changed still cannot be arbitrated server-side the way a re-published
      // post now is (`create_post_with_media()` rewrites its row on a repeat
      // token, migration 20260824100000), because `comments` has no UPDATE
      // policy on purpose — see data-model.md. Between the two outcomes, a
      // duplicate comment is something its author can delete, whereas an
      // edit discarded under a reused token is gone with no sign it existed.
      // Hence the trade stays this way round.
      await _load();
      if (!mounted) return;
      // A snackbar, not _errorMessage: that field is rendered only in place of
      // the list, so once comments have loaded — which is the normal state when
      // sending — assigning to it puts the message nowhere. The composer would
      // just stop, and the server rejects a reply for several ordinary reasons
      // (its target was deleted or blocked while the reply was being typed).
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
                    // Сноска идёт последним элементом ТОГО ЖЕ списка, а не
                    // отдельным блоком под ним: обрезается хвост, и сказать об
                    // этом надо там, где хвост кончился.
                    itemCount: _comments!.length + (_isTruncated ? 1 : 0),
                    itemBuilder: (context, index) => index == _comments!.length
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              l10n.commentsTruncatedNotice(commentFetchLimit),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          )
                        : _buildComment(l10n, _comments![index]),
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
