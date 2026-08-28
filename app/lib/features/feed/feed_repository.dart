import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../shared/delete_order.dart';
import '../../shared/media_bucket.dart';
import '../../shared/network_timeout.dart';
import '../../shared/parse_timestamp.dart';
import '../../shared/system_accounts.dart';
import '../../shared/tolerant_upload.dart';
import '../auth/auth_providers.dart';

/// The three mutually-exclusive reactions a user can leave on a post. Stored
/// in `reactions.type` as the enum's [name] (`like` / `neutral` / `dislike`).
enum ReactionType {
  like,
  neutral,
  dislike;

  static ReactionType fromDb(String value) => ReactionType.values.byName(value);

  String get dbValue => name;
}

/// What kind of file a [PostMedia] slot holds. Stored in `post_media.media_type`
/// as the enum's [name] (`image` / `video`).
enum MediaType {
  image,
  video;

  static MediaType fromDb(String value) => MediaType.values.byName(value);

  String get dbValue => name;
}

/// Sentinel so [Post.copyWith] can tell "leave myReaction unchanged" apart
/// from "clear it to null" — a plain nullable parameter can't express both.
const Object _unchanged = Object();

/// One photo or video attached to a post. A post can have up to 20, ordered by
/// [position] (a display order, not necessarily a dense 0..N-1 sequence — see
/// the comment on `post_media` in the migration).
class PostMedia {
  const PostMedia({
    required this.id,
    required this.position,
    required this.mediaType,
    required this.storagePath,
    this.posterPath,
    this.url,
    this.posterUrl,
  });

  final String id;
  final int position;
  final MediaType mediaType;
  final String storagePath;

  /// Path of the video's poster frame (generated client-side at pick time).
  /// Always null for [MediaType.image].
  final String? posterPath;

  /// Resolved signed URL for [storagePath], or null until fetched — the feed
  /// only eagerly resolves each post's first slide (see [FeedRepository.fetchPage]);
  /// the rest are resolved lazily as the user swipes.
  final String? url;
  final String? posterUrl;

  factory PostMedia.fromRow(Map<String, dynamic> row) => PostMedia(
    id: row['id'] as String,
    position: (row['position'] as num).toInt(),
    mediaType: MediaType.fromDb(row['media_type'] as String),
    storagePath: row['storage_path'] as String,
    posterPath: row['poster_path'] as String?,
  );

  PostMedia copyWith({String? url, String? posterUrl}) => PostMedia(
    id: id,
    position: position,
    mediaType: mediaType,
    storagePath: storagePath,
    posterPath: posterPath,
    url: url ?? this.url,
    posterUrl: posterUrl ?? this.posterUrl,
  );

  Map<String, dynamic> toCacheJson() => {
    'id': id,
    'position': position,
    'media_type': mediaType.dbValue,
    'storage_path': storagePath,
    'poster_path': posterPath,
    'url': url,
    'poster_url': posterUrl,
  };

  factory PostMedia.fromCacheJson(Map<String, dynamic> json) => PostMedia(
    id: json['id'] as String,
    position: (json['position'] as num).toInt(),
    mediaType: MediaType.fromDb(json['media_type'] as String),
    storagePath: json['storage_path'] as String,
    posterPath: json['poster_path'] as String?,
    url: json['url'] as String?,
    posterUrl: json['poster_url'] as String?,
  );
}

class Post {
  const Post({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.createdAt,
    this.clientToken,
    this.authorDislikesDisabled = false,
    this.text,
    this.media = const [],
    this.likeCount = 0,
    this.neutralCount = 0,
    this.dislikeCount = 0,
    this.myReaction,
    this.commentCount = 0,
  });

  final String id;
  final String authorId;
  final String authorName;
  final DateTime createdAt;

  /// The idempotency token this post's row was created with. Null only for
  /// posts created before `client_token` existed (20260818120000) — the
  /// column is nullable for exactly that reason. Used as the storage path
  /// prefix for any *new* media added while editing; a legacy null is handled
  /// by minting a fresh token for the edit session (see the composer screen),
  /// never by assuming this is non-null.
  final String? clientToken;

  /// The author opted out of negative reactions: the dislike button is hidden
  /// under their posts (and the database rejects a dislike on them). Sourced
  /// from the author's profile, so nothing in this code names a specific user.
  final bool authorDislikesDisabled;
  final String? text;

  /// Up to 20 photos/videos, ordered for the feed's swipe carousel. Empty for
  /// a text-only post.
  final List<PostMedia> media;
  final int likeCount;
  final int neutralCount;
  final int dislikeCount;

  /// The current user's reaction on this post, or null if they haven't reacted.
  final ReactionType? myReaction;
  final int commentCount;

  factory Post.fromRow(Map<String, dynamic> row) {
    final mediaRows =
        ((row['media'] as List<dynamic>?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(PostMedia.fromRow)
            .toList()
          ..sort((a, b) => a.position.compareTo(b.position));
    return Post(
      id: row['id'] as String,
      authorId: row['author_id'] as String,
      authorName: (row['author'] as Map<String, dynamic>)['name'] as String,
      createdAt: parseTimestamp(row['created_at'] as String),
      clientToken: row['client_token'] as String?,
      authorDislikesDisabled:
          (row['author'] as Map<String, dynamic>)['dislikes_disabled']
              as bool? ??
          false,
      text: row['text'] as String?,
      media: mediaRows,
    );
  }

  Post copyWith({
    List<PostMedia>? media,
    int? likeCount,
    int? neutralCount,
    int? dislikeCount,
    Object? myReaction = _unchanged,
    int? commentCount,
  }) {
    return Post(
      id: id,
      authorId: authorId,
      authorName: authorName,
      createdAt: createdAt,
      clientToken: clientToken,
      authorDislikesDisabled: authorDislikesDisabled,
      text: text,
      media: media ?? this.media,
      likeCount: likeCount ?? this.likeCount,
      neutralCount: neutralCount ?? this.neutralCount,
      dislikeCount: dislikeCount ?? this.dislikeCount,
      myReaction: identical(myReaction, _unchanged)
          ? this.myReaction
          : myReaction as ReactionType?,
      commentCount: commentCount ?? this.commentCount,
    );
  }

  /// Serializes for [FeedCache] — a local snapshot of the last-seen feed, not
  /// a wire format, so it's free to just mirror the fields directly rather
  /// than matching [fromRow]'s row shape.
  Map<String, dynamic> toCacheJson() => {
    'id': id,
    'author_id': authorId,
    'author_name': authorName,
    'created_at': createdAt.toIso8601String(),
    'client_token': clientToken,
    'author_dislikes_disabled': authorDislikesDisabled,
    'text': text,
    'media': media.map((m) => m.toCacheJson()).toList(),
    'like_count': likeCount,
    'neutral_count': neutralCount,
    'dislike_count': dislikeCount,
    'my_reaction': myReaction?.dbValue,
    'comment_count': commentCount,
  };

  factory Post.fromCacheJson(Map<String, dynamic> json) => Post(
    id: json['id'] as String,
    authorId: json['author_id'] as String,
    authorName: json['author_name'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    clientToken: json['client_token'] as String?,
    authorDislikesDisabled: json['author_dislikes_disabled'] as bool? ?? false,
    text: json['text'] as String?,
    // A cache written by an older app version has no `media` key (it had
    // `image_path`/`image_url` instead) — default to no photo rather than
    // throwing and losing the whole cached page over one stale field.
    media:
        (json['media'] as List<dynamic>?)
            ?.map((m) => PostMedia.fromCacheJson(m as Map<String, dynamic>))
            .toList() ??
        const [],
    likeCount: json['like_count'] as int? ?? 0,
    neutralCount: json['neutral_count'] as int? ?? 0,
    dislikeCount: json['dislike_count'] as int? ?? 0,
    myReaction: json['my_reaction'] != null
        ? ReactionType.fromDb(json['my_reaction'] as String)
        : null,
    commentCount: json['comment_count'] as int? ?? 0,
  );
}

/// Returns [post] with its counters and `myReaction` moved from whatever the
/// viewer had to [next] (null = no reaction at all).
///
/// The feed applies this optimistically, before the server has confirmed
/// anything, so it has to do the same arithmetic the server would: take one off
/// the old counter, add one to the new. Lives here as a pure function rather
/// than inside the screen's State so the six transitions can be tested — the
/// counters are what the user actually looks at, and an off-by-one here is
/// invisible until someone counts.
Post applyReaction(Post post, ReactionType? next) {
  var like = post.likeCount;
  var neutral = post.neutralCount;
  var dislike = post.dislikeCount;
  switch (post.myReaction) {
    case ReactionType.like:
      like--;
    case ReactionType.neutral:
      neutral--;
    case ReactionType.dislike:
      dislike--;
    case null:
      break;
  }
  switch (next) {
    case ReactionType.like:
      like++;
    case ReactionType.neutral:
      neutral++;
    case ReactionType.dislike:
      dislike++;
    case null:
      break;
  }
  return post.copyWith(
    likeCount: like,
    neutralCount: neutral,
    dislikeCount: dislike,
    myReaction: next,
  );
}

class Comment {
  const Comment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.text,
    required this.createdAt,
    this.parentCommentId,
    this.replyToId,
    this.isDeleted = false,
  });

  final String id;
  final String authorId;
  final String authorName;
  final String text;
  final DateTime createdAt;

  /// The thread root this comment belongs to; null for a root comment. Replies
  /// are capped at one level, so a reply's parent is always a root.
  final String? parentCommentId;

  /// The comment this reply is addressed to — the root itself or a sibling
  /// reply. Display only: it never affects nesting.
  final String? replyToId;

  /// A comment that was deleted while it still had replies: the row survives so
  /// the thread stays readable, but [text] has been erased server-side.
  final bool isDeleted;

  factory Comment.fromRow(Map<String, dynamic> row) {
    return Comment(
      id: row['id'] as String,
      authorId: row['author_id'] as String,
      authorName: (row['author'] as Map<String, dynamic>)['name'] as String,
      text: row['text'] as String,
      createdAt: parseTimestamp(row['created_at'] as String),
      parentCommentId: row['parent_comment_id'] as String?,
      replyToId: row['reply_to_id'] as String?,
      isDeleted: row['deleted_at'] != null,
    );
  }
}

/// How many comments one [FeedRepository.fetchComments] call will return.
///
/// Not a page size — there is no "load more" behind it, and deliberately so:
/// this is a ceiling that keeps one request finishing, not pagination. Set far
/// above any thread this app is expected to grow (a private feed of real
/// acquaintances), so reaching it is the pathological case rather than the
/// normal one.
const commentFetchLimit = 500;

/// One [FeedRepository.fetchComments] result: the comments, and whether the
/// post has more than [commentFetchLimit] of them.
///
/// [isTruncated] is not cosmetic. The comment counter on a post's card comes
/// from `comment_summary()`, which counts every visible non-tombstoned row
/// server-side — so once the list is cut, its length stops being that number
/// and must not be reported as it. See [CommentsScreen.onCountChanged].
class CommentPage {
  const CommentPage({required this.comments, required this.isTruncated});

  final List<Comment> comments;
  final bool isTruncated;
}

/// One picked-but-not-yet-uploaded photo or video, held by the composer
/// screen's local state. Distinct from [PostMedia] (a *server* row): this
/// models a pending upload, before it has a `post_media` id at all.
/// Where a picked item's payload lives until it is uploaded.
///
/// Images are held as bytes because the composer paints them anyway (they are
/// downscaled to `maxWidth: 1600` at pick time, so a few hundred KB each).
/// Video is held as a path: it is never transcoded, a 60 s 1080p clip is
/// 50–100 MB, and nothing on screen needs its bytes — the composer preview and
/// the feed both show the poster frame.
///
/// This bounds *concurrent* residency, not the read itself. Every upload path
/// available in storage_client 2.6.0 ends in `MultipartFile.fromBytes`, so a
/// clip is in memory while it uploads no matter what (see
/// [uploadTolerantFile]). What changes is that it is read when its turn comes
/// and dropped afterwards, instead of all 20 slots being read at pick time and
/// held for the whole composer session — which is where the hundreds of
/// megabytes to over a gigabyte came from.
sealed class MediaSource {
  const MediaSource();
}

class MediaBytes extends MediaSource {
  const MediaBytes(this.bytes);
  final Uint8List bytes;
}

class MediaFile extends MediaSource {
  const MediaFile(this.path);
  final String path;
}

class PendingMedia {
  const PendingMedia({
    required this.mediaClientToken,
    required this.mediaType,
    required this.source,
    required this.ext,
    this.posterBytes,
  });

  /// Minted client-side at pick time, not at submit time — stable across
  /// retries of the same publish/save attempt, and what makes the item's
  /// storage path (and the retry-idempotency built on it) deterministic.
  final String mediaClientToken;
  final MediaType mediaType;
  final MediaSource source;
  final String ext;

  /// JPEG poster frame, generated client-side at pick time. Required for
  /// video, always null for image.
  final Uint8List? posterBytes;
}

/// One slot in the composer's final, ordered media list while editing an
/// existing post: either an already-uploaded item kept from the original post,
/// or a freshly picked one to upload. [FeedRepository.updatePost] diffs this
/// list against the post's original media to know what to delete/upload/keep.
sealed class ComposerMediaItem {
  const ComposerMediaItem();
}

class KeptMedia extends ComposerMediaItem {
  const KeptMedia(this.media);
  final PostMedia media;
}

class NewMedia extends ComposerMediaItem {
  const NewMedia(this.pending);
  final PendingMedia pending;
}

const pageSize = 20;

/// How long a signed URL for a post's media stays valid before it needs
/// re-resolving.
const _signedUrlTtl = 60 * 60 * 24;

/// Builds the PostgREST keyset filter for the page strictly *older* than
/// [cursor], newest-first. Returns null for the first page (no cursor).
///
/// Keyset (seek) paging instead of offset paging: the window is anchored to the
/// last post already seen — `created_at < cursor` — rather than to a numeric
/// offset. That way posts inserted at (or deleted from) the top between page
/// loads can't shift the offset and cause a post to be shown twice or skipped.
/// `created_at` alone isn't unique, so `id` is a deterministic tiebreak for the
/// rare case of two posts sharing the exact same timestamp at a page boundary.
String? keysetFilter(Post? cursor) {
  if (cursor == null) return null;
  final ts = cursor.createdAt.toUtc().toIso8601String();
  return 'created_at.lt.$ts,and(created_at.eq.$ts,id.lt.${cursor.id})';
}

/// Storage path for one media item of a post.
///
/// Three things are load-bearing here. The first two segments are what the
/// storage policies match on — `posts/<author uuid>/…` — so reshaping this
/// silently breaks upload (the INSERT policy pins segment 2 to `auth.uid()`)
/// or visibility (the SELECT policy reads the author out of that segment).
/// The third segment, [postClientToken], groups every media item of one post
/// under a single prefix, which is what lets [FeedRepository.deletePost]'s
/// caller hand over a flat list of paths instead of tracking each one
/// separately. The filename is [mediaClientToken] — minted per item at pick
/// time, not per attempt — so retrying a specific item's upload addresses the
/// same object instead of leaking a duplicate into the bucket. It is
/// deliberately *not* the item's display [PostMedia.position]: position can
/// change on reorder, but the storage object's identity must not — reorder is
/// therefore always a `post_media` row change, never a Storage operation.
String postMediaPath({
  required String authorId,
  required String postClientToken,
  required String mediaClientToken,
  required String ext,
}) => 'posts/$authorId/$postClientToken/$mediaClientToken.$ext';

/// Path of a video's poster frame — same prefix as its video, own file.
String postMediaPosterPath({
  required String authorId,
  required String postClientToken,
  required String mediaClientToken,
}) => 'posts/$authorId/$postClientToken/${mediaClientToken}_poster.jpg';

class FeedRepository {
  FeedRepository(this._client, this._systemAccounts);

  final SupabaseClient _client;

  /// Which authors count as system accounts — the server's answer, shared with
  /// every other caller that needs it. See [SystemAccounts].
  final SystemAccounts _systemAccounts;

  /// Fetches one page of the feed (newest first), starting strictly after
  /// [cursor] (the last post of the previous page; null for the first page).
  /// When [authorId] is set, only that author's posts are returned — used by
  /// the profile screen's "my posts" list, layered on top of the same RLS
  /// visibility rather than replacing it.
  ///
  /// The system account stays in `visible_author_ids()` (its profile is still
  /// reachable directly, via [authorId]) but is excluded here on the
  /// unscoped call — its posts no longer clutter the general feed.
  ///
  /// Each post's *first* media slide gets a signed URL resolved eagerly here
  /// (the `media` bucket is private, so a plain public URL wouldn't be
  /// servable) — the rest of a multi-media post's slides are resolved lazily
  /// via [resolveMediaUrls] as the carousel approaches them, since a post
  /// can carry up to 20 items and resolving all of them for every post on
  /// every page would multiply this call's cost by up to 20x for slides most
  /// users never see.
  Future<List<Post>> fetchPage({Post? cursor, String? authorId}) async {
    var query = _client
        .from('posts')
        .select(
          '*, author:users(name, dislikes_disabled), media:post_media(*)',
        );
    if (authorId != null) {
      query = query.eq('author_id', authorId);
    } else {
      final excluded = await _systemAccounts.ids();
      // Skipped rather than sent empty: `not.in.()` is not a filter PostgREST
      // accepts, it is a 400 — and [SystemAccounts] caches its answer, so one
      // empty result would have wedged the feed for the rest of the session
      // while the offline fallback stood by unused (the lookup *succeeded*, it
      // just said "none"). No system accounts means nothing to leave out.
      if (excluded.isNotEmpty) {
        query = query.not('author_id', 'in', '(${excluded.join(',')})');
      }
    }
    final filter = keysetFilter(cursor);
    if (filter != null) {
      query = query.or(filter);
    }
    final rows = await query
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .order('position', referencedTable: 'post_media', ascending: true)
        .limit(pageSize)
        .timeout(networkTimeout);

    var posts = rows.map(Post.fromRow).toList();
    if (posts.isEmpty) return posts;

    final postIds = posts.map((p) => p.id).toList();

    // Reaction *counts* are public to anyone who can see the post, but who
    // reacted is not: the reactions table only exposes the caller's own rows,
    // so totals come from a server-side function that returns numbers plus the
    // caller's own reaction — never other users' ids.
    //
    // Counts every comment including replies, but not tombstones (a deleted
    // comment's row survives only to keep its branch readable and holds no
    // text). Server-side: the comments SELECT policy already gates exactly
    // these rows, so `comment_summary` needs no visibility logic of its own.
    //
    // Neither RPC depends on the other's result, so they run concurrently
    // instead of costing the page an extra round trip.
    final results = await Future.wait([
      _client
          .rpc('reaction_summary', params: {'p_post_ids': postIds})
          .timeout(networkTimeout),
      _client
          .rpc('comment_summary', params: {'p_post_ids': postIds})
          .timeout(networkTimeout),
    ]);
    final summaryRows = results[0] as List<dynamic>;
    final commentSummaryRows = results[1] as List<dynamic>;

    final likeCounts = <String, int>{};
    final neutralCounts = <String, int>{};
    final dislikeCounts = <String, int>{};
    final myReactions = <String, ReactionType>{};
    for (final row in summaryRows.cast<Map<String, dynamic>>()) {
      final postId = row['post_id'] as String;
      likeCounts[postId] = (row['like_count'] as num).toInt();
      neutralCounts[postId] = (row['neutral_count'] as num).toInt();
      dislikeCounts[postId] = (row['dislike_count'] as num).toInt();
      final mine = row['my_reaction'] as String?;
      if (mine != null) myReactions[postId] = ReactionType.fromDb(mine);
    }

    final commentCounts = <String, int>{};
    for (final row in commentSummaryRows.cast<Map<String, dynamic>>()) {
      final postId = row['post_id'] as String;
      commentCounts[postId] = (row['comment_count'] as num).toInt();
    }

    posts = posts
        .map(
          (post) => post.copyWith(
            likeCount: likeCounts[post.id] ?? 0,
            neutralCount: neutralCounts[post.id] ?? 0,
            dislikeCount: dislikeCounts[post.id] ?? 0,
            myReaction: myReactions[post.id],
            commentCount: commentCounts[post.id] ?? 0,
          ),
        )
        .toList();

    // Batch-resolve every post's first slide (plus its poster, if that first
    // slide is a video) in one round trip rather than one `createSignedUrl`
    // call per post — the storage API signs a whole list of paths at once.
    final firstSlidePaths = <String>[];
    for (final post in posts) {
      if (post.media.isEmpty) continue;
      final first = post.media.first;
      firstSlidePaths.add(first.storagePath);
      final poster = first.posterPath;
      if (poster != null) firstSlidePaths.add(poster);
    }
    if (firstSlidePaths.isEmpty) return posts;

    final signedByPath = await resolveMediaUrls(firstSlidePaths);

    return posts.map((post) {
      if (post.media.isEmpty) return post;
      final first = post.media.first;
      final resolvedFirst = first.copyWith(
        url: signedByPath[first.storagePath],
        posterUrl: first.posterPath != null
            ? signedByPath[first.posterPath!]
            : null,
      );
      return post.copyWith(media: [resolvedFirst, ...post.media.skip(1)]);
    }).toList();
  }

  /// Signs a batch of media paths in a single round trip — how a carousel
  /// resolves the slides beyond the first, rather than eagerly resolving all
  /// up to 20 items in [fetchPage]. Batched because a slide plus its poster,
  /// and the slide on either side of the current one, are wanted at the same
  /// moment: one request instead of up to six.
  ///
  /// Paths the storage API refuses to sign are simply absent from the result,
  /// leaving those slides unresolved (and retried on the next swipe) instead
  /// of failing the whole batch.
  Future<Map<String, String>> resolveMediaUrls(
    List<String> storagePaths,
  ) async {
    if (storagePaths.isEmpty) return const {};
    final results = await _client.storage
        .from(mediaBucket)
        .createSignedUrlsResult(storagePaths, _signedUrlTtl)
        .timeout(networkTimeout);
    return {
      for (final r in results)
        if (r is SignedUrlSuccess) r.path: r.signedUrl,
    };
  }

  Future<void> _uploadTolerant(String path, Uint8List bytes) =>
      uploadTolerant(_client, bucket: mediaBucket, path: path, bytes: bytes);

  Future<void> _uploadSource(String path, MediaSource source) =>
      switch (source) {
        MediaBytes(:final bytes) => _uploadTolerant(path, bytes),
        MediaFile(path: final sourcePath) => uploadTolerantFile(
          _client,
          bucket: mediaBucket,
          path: path,
          file: File(sourcePath),
        ),
      };

  Future<void> _uploadMediaItem({
    required String authorId,
    required String postClientToken,
    required PendingMedia item,
  }) async {
    await _uploadSource(
      postMediaPath(
        authorId: authorId,
        postClientToken: postClientToken,
        mediaClientToken: item.mediaClientToken,
        ext: item.ext,
      ),
      item.source,
    );
    final posterBytes = item.posterBytes;
    if (posterBytes != null) {
      await _uploadTolerant(
        postMediaPosterPath(
          authorId: authorId,
          postClientToken: postClientToken,
          mediaClientToken: item.mediaClientToken,
        ),
        posterBytes,
      );
    }
  }

  /// One entry of the `p_items` array both `create_post_with_media()` and
  /// `set_post_media()` take: what this media slot *is*, with no `post_id` and
  /// no `position` — the server derives the position from the array order, so
  /// the client's job is only to send them in the order it wants them shown.
  Map<String, dynamic> _pendingMediaItem({
    required String authorId,
    required String postClientToken,
    required PendingMedia item,
  }) => {
    'media_type': item.mediaType.dbValue,
    'storage_path': postMediaPath(
      authorId: authorId,
      postClientToken: postClientToken,
      mediaClientToken: item.mediaClientToken,
      ext: item.ext,
    ),
    if (item.posterBytes != null)
      'poster_path': postMediaPosterPath(
        authorId: authorId,
        postClientToken: postClientToken,
        mediaClientToken: item.mediaClientToken,
      ),
  };

  /// [clientToken] identifies this *submission* — the caller mints one uuid per
  /// composed post and reuses it for every retry of that same content, and it
  /// also doubles as the storage-path prefix shared by every one of [media]'s
  /// items (see [postMediaPath]).
  ///
  /// The post row and its `post_media` rows are written by ONE call to
  /// `create_post_with_media()`, so they land in one transaction or not at all.
  /// This used to be three PostgREST calls — insert the post, read its id back,
  /// insert the media — which is three transactions, and `.timeout()` stops
  /// waiting without cancelling. A commit of the first followed by a lost
  /// second published a post that had text and no photographs: live in every
  /// connection's feed, its "new post" push already sent by
  /// `enqueue_post_notifications`, while this method threw and the composer
  /// told the author nothing had been saved. `purge_empty_posts` could not
  /// clean that up either — it only removes posts with *no* text.
  ///
  /// Retrying never produces a second post: the server arbitrates on the same
  /// `(author_id, client_token)` index as before, and each media item's own
  /// retry-tolerant upload (409) makes the whole multi-file submission safe to
  /// retry as a unit.
  ///
  /// A repeat token is no longer answered by doing *nothing*, though — since
  /// migration 20260824100000 it rewrites the post to whatever this call sent.
  /// That is what lets the composer mint one token per session instead of one
  /// per version of the draft: a retry whose content changed in between (fix a
  /// typo after a publish that timed out but committed anyway) updates the
  /// post that already exists rather than publishing a rival copy of it. See
  /// the note on `_submissionToken` in the composer for the failure this
  /// closes.
  ///
  /// A rewrite can therefore *drop* media the first attempt had already
  /// uploaded — remove a photo from the draft before publishing again and its
  /// object is left in the bucket with no row naming it. So this goes through
  /// [deleteRowsThenObjects] exactly like [updatePost]: since migration
  /// 20260825110000 `create_post_with_media()` returns the storage paths its
  /// rewrite orphaned, and the bucket cleanup runs after the row write has
  /// committed and is best-effort. `reap_orphaned_media()` is the backstop for
  /// when this never runs at all — it only collects objects older than 24 h,
  /// a hundred at a time, which is the wrong instrument for a 100 MB clip the
  /// author removed from the draft a second ago.
  Future<void> createPost({
    required String clientToken,
    required String authorId,
    String? text,
    List<PendingMedia> media = const [],
  }) async {
    for (final item in media) {
      await _uploadMediaItem(
        authorId: authorId,
        postClientToken: clientToken,
        item: item,
      );
    }

    var orphanedPaths = const <String>[];
    await deleteRowsThenObjects(
      rows: () async {
        final orphaned = await _client
            .rpc(
              'create_post_with_media',
              params: {
                'p_client_token': clientToken,
                'p_text': (text != null && text.isNotEmpty) ? text : null,
                'p_items': [
                  for (final item in media)
                    _pendingMediaItem(
                      authorId: authorId,
                      postClientToken: clientToken,
                      item: item,
                    ),
                ],
              },
            )
            .timeout(networkTimeout);

        // `returns table (storage_path text)`, so PostgREST hands these back
        // as rows — the same shape as [updatePost]'s half of this rule. Empty
        // on a first publish, which is the ordinary case.
        orphanedPaths = [
          for (final row in (orphaned as List<dynamic>? ?? const []))
            (row as Map<String, dynamic>)['storage_path'] as String,
        ];
      },
      objects: () async {
        if (orphanedPaths.isEmpty) return;
        await _client.storage
            .from(mediaBucket)
            .remove(orphanedPaths)
            .timeout(networkTimeout);
      },
    );
  }

  /// Saves edits to a post the current user owns: [text] and/or its media.
  ///
  /// [finalMedia] is the composer's final ordered list — a mix of items kept
  /// from the original post ([KeptMedia]) and freshly picked ones
  /// ([NewMedia]). New files are uploaded first, then the caption and the
  /// whole media set are handed to `update_post_with_media()`, which applies
  /// both in **one transaction** and returns the storage paths nothing
  /// references any more, for this method to delete afterwards.
  ///
  /// The server does the diffing (which is why the post's original media is
  /// no longer a parameter) for a reason that is not tidiness. This used to
  /// be a DELETE of the surviving rows followed by a separate INSERT at their
  /// new positions — two PostgREST calls, so two transactions, with nothing
  /// in between. A failure after the first (and `.timeout()` stops waiting
  /// without cancelling, so that is an ordinary Tuesday on a bad connection)
  /// left the post with *no media rows at all*, while its files sat on in
  /// Storage referenced by nothing.
  ///
  /// Storage deletions come last, after the row write has already committed,
  /// and are best-effort — [deleteRowsThenObjects] states the rule and this is
  /// one of its call sites. An object nothing points at is wasted bucket
  /// space, whereas a row pointing at a deleted object is a broken image in
  /// everyone's feed, and a failed cleanup must never be reported as a failed
  /// save.
  ///
  /// [postClientToken] is the prefix new media is uploaded under — normally
  /// the post's own [Post.clientToken], but the caller mints a fresh one for
  /// a legacy post that predates that column (see [Post.clientToken]).
  Future<void> updatePost({
    required String postId,
    required String authorId,
    required String postClientToken,
    String? text,
    required List<ComposerMediaItem> finalMedia,
  }) async {
    for (final item in finalMedia.whereType<NewMedia>()) {
      await _uploadMediaItem(
        authorId: authorId,
        postClientToken: postClientToken,
        item: item.pending,
      );
    }

    final items = [
      for (final slot in finalMedia)
        switch (slot) {
          KeptMedia(:final media) => {
            'media_type': media.mediaType.dbValue,
            'storage_path': media.storagePath,
            if (media.posterPath != null) 'poster_path': media.posterPath,
          },
          NewMedia(:final pending) => _pendingMediaItem(
            authorId: authorId,
            postClientToken: postClientToken,
            item: pending,
          ),
        },
    ];

    // The row half of the save is now a single statement, and the bucket
    // cleanup is the object half — the shape [deleteRowsThenObjects] exists
    // for, so it runs through it rather than open-coding a third variant of
    // the rule.
    //
    // The caption and the media set used to be two PostgREST calls, i.e. two
    // transactions, and their ordering had already been reversed once to stop
    // a timed-out caption update from stranding a dropped file in the bucket
    // with nothing left able to name it (`set_post_media` had by then returned
    // its removed-list to a call that threw). What that reordering could not
    // fix is the pair itself: a caption that lands followed by a failed media
    // rewrite reports failure with the caption already applied.
    //
    // `update_post_with_media()` (migration 20260824120000) takes both halves,
    // so there is no longer a between. It also enforces, on this path, the
    // "a post needs text or media" rule that `create_post_with_media()` has
    // enforced on the publish path since 20260823120000 — the check was not
    // expressible while the two halves arrived separately, because neither
    // call could see the other's contribution.
    //
    // Storage deletions still come last and are still best-effort. An object
    // nothing points at is wasted bucket space; a row pointing at a deleted
    // object is a broken image in everyone's feed, and a failed cleanup must
    // never be reported as a failed save.
    var orphanedPaths = const <String>[];
    await deleteRowsThenObjects(
      rows: () async {
        final orphaned = await _client
            .rpc(
              'update_post_with_media',
              params: {
                'p_post_id': postId,
                'p_text': (text != null && text.isNotEmpty) ? text : null,
                'p_items': items,
              },
            )
            .timeout(networkTimeout);

        // `returns table (storage_path text)`, so PostgREST hands these back
        // as rows — the same shape as every other RPC in this project.
        orphanedPaths = [
          for (final row in (orphaned as List<dynamic>? ?? const []))
            (row as Map<String, dynamic>)['storage_path'] as String,
        ];
      },
      objects: () async {
        if (orphanedPaths.isEmpty) return;
        await _client.storage
            .from(mediaBucket)
            .remove(orphanedPaths)
            .timeout(networkTimeout);
      },
    );
  }

  /// Sets (or switches) the current user's reaction on a post. Upserts onto
  /// the unique (post_id, user_id) row, so switching like -> dislike replaces
  /// the type rather than adding a second reaction.
  Future<void> setReaction({
    required String postId,
    required String userId,
    required ReactionType type,
  }) async {
    await _client
        .from('reactions')
        .upsert({
          'post_id': postId,
          'user_id': userId,
          'type': type.dbValue,
        }, onConflict: 'post_id, user_id')
        .timeout(networkTimeout);
  }

  Future<void> removeReaction({
    required String postId,
    required String userId,
  }) async {
    await _client
        .from('reactions')
        .delete()
        .eq('post_id', postId)
        .eq('user_id', userId)
        .timeout(networkTimeout);
  }

  /// Fetches one post's comments, oldest first — a conversation reads forwards,
  /// and replies have to follow the comment they answer.
  ///
  /// `ascending: true` is spelled out because postgrest-dart's `order()`
  /// defaults to *descending*; `id` is a deterministic tiebreak for comments
  /// sharing a timestamp, same as the feed's keyset paging.
  ///
  /// Capped at [commentFetchLimit]. This used to be unbounded — the one query
  /// in the app that was, while the feed right above it went to the trouble of
  /// keyset paging — so a post with thousands of comments pulled all of them,
  /// with their author join, into a single response. Past a certain size that
  /// simply cannot finish inside [networkTimeout], and the screen then reports
  /// "failed to load comments" on every attempt with no way through: not a slow
  /// load, a dead end, the same shape [uploadTimeout] was written to close for
  /// video.
  ///
  /// The cut is at the *end* on purpose. Comments arrive oldest-first, so
  /// dropping the tail can orphan a reply from its root but never a root from
  /// its replies, and [threadComments] already hides a reply whose root is
  /// missing. Cutting the other way — newest N — would strand replies whose
  /// root fell outside the window, which is most of them.
  Future<CommentPage> fetchComments(String postId) async {
    // One more than the cap: the extra row is how "there are more" is known
    // without a second count query.
    final rows = await _client
        .from('comments')
        .select('*, author:users(name)')
        .eq('post_id', postId)
        .order('created_at', ascending: true)
        .order('id', ascending: true)
        .limit(commentFetchLimit + 1)
        .timeout(networkTimeout);
    final isTruncated = rows.length > commentFetchLimit;
    return CommentPage(
      comments: rows.take(commentFetchLimit).map(Comment.fromRow).toList(),
      isTruncated: isTruncated,
    );
  }

  /// Adds a comment, or a reply when [parentCommentId] is given (always the
  /// thread root — nesting is one level deep). [replyToId] only records who the
  /// reply addresses, for the `in reply to: <name>` label.
  ///
  /// [clientToken] identifies this submission and is reused across retries of
  /// the same content — see the matching note on [createPost].
  Future<void> addComment({
    required String clientToken,
    required String postId,
    required String authorId,
    required String text,
    String? parentCommentId,
    String? replyToId,
  }) async {
    await _client
        .from('comments')
        .upsert(
          {
            'client_token': clientToken,
            'post_id': postId,
            'author_id': authorId,
            'text': text,
            'parent_comment_id': parentCommentId,
            'reply_to_id': replyToId,
          },
          onConflict: 'author_id,client_token',
          ignoreDuplicates: true,
        )
        .timeout(networkTimeout);
  }

  /// Deletes a post the current user owns. Comments/reactions cascade via
  /// their FK to `posts`, and so does `post_media` — but its media lives in
  /// Storage, not Postgres, so [mediaStoragePaths] (every media item's
  /// storage path, plus video poster paths — the caller already has these on
  /// the loaded [Post.media]) is removed separately, in one batch call.
  ///
  /// Ordering — and the reason for it — lives in [deleteRowsThenObjects].
  /// The storage DELETE policy matches on the `posts/<uid>/…` path alone, so
  /// the cleanup stays permitted after the row is gone.
  Future<void> deletePost({
    required String postId,
    List<String> mediaStoragePaths = const [],
  }) {
    return deleteRowsThenObjects(
      rows: () => _client
          .from('posts')
          .delete()
          .eq('id', postId)
          .timeout(networkTimeout),
      objects: () async {
        if (mediaStoragePaths.isEmpty) return;
        await _client.storage
            .from(mediaBucket)
            .remove(mediaStoragePaths)
            .timeout(networkTimeout);
      },
    );
  }

  /// Deletes a comment of the current user's. Whether the row is removed or
  /// merely tombstoned is decided server-side (a comment with replies is
  /// tombstoned so those replies keep their context), hence the RPC instead of
  /// a plain delete.
  Future<void> deleteComment(String commentId) async {
    await _client
        .rpc('delete_own_comment', params: {'p_comment_id': commentId})
        .timeout(networkTimeout);
  }
}

final feedRepositoryProvider = Provider<FeedRepository>((ref) {
  return FeedRepository(
    ref.watch(supabaseClientProvider),
    ref.watch(systemAccountsProvider),
  );
});

/// Bumped whenever something outside [FeedScreen] changes what the feed should
/// show, so it can refresh itself: a post created from the bottom-nav "new
/// post" tab, an edit saved from a post's own menu, and muting/blocking (or
/// unmuting/unblocking) a connection, which changes which authors RLS lets
/// through. The feed tab keeps its state in the shell's IndexedStack, so
/// without this it would sit on a stale page.
class FeedRefreshTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final feedRefreshTickProvider = NotifierProvider<FeedRefreshTick, int>(
  FeedRefreshTick.new,
);
