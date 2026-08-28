import 'package:supabase_flutter/supabase_flutter.dart';

import 'media_bucket.dart';
import 'network_timeout.dart';

/// How long a signed URL for a media object stays valid before it needs
/// re-resolving.
const signedUrlTtl = 60 * 60 * 24;

/// Signs [storagePaths] in one round trip and returns URL by path.
///
/// The `media` bucket is private, so nothing in it is displayable without
/// this. Batched deliberately: a post's carousel, or one chat message, can
/// carry several objects at the same moment, and that is one request instead
/// of up to six.
///
/// Paths the storage API refuses to sign are simply absent from the result,
/// leaving those slides unresolved (and retried on the next swipe) instead
/// of failing the whole batch.
///
/// One copy for every caller: the feed and the room chat sign objects out of
/// the same bucket, and a second TTL would drift from this one.
Future<Map<String, String>> resolveSignedUrls(
  SupabaseClient client,
  List<String> storagePaths,
) async {
  if (storagePaths.isEmpty) return const {};
  final results = await client.storage
      .from(mediaBucket)
      .createSignedUrlsResult(storagePaths, signedUrlTtl)
      .timeout(networkTimeout);
  return {
    for (final r in results)
      if (r is SignedUrlSuccess) r.path: r.signedUrl,
  };
}
