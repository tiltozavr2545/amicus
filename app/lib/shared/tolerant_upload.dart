import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'network_timeout.dart';

/// Uploads [bytes] to [path], treating "an object is already there" as
/// success rather than as a failure.
///
/// Every storage path in this app is addressed by a client-minted token
/// (`postMediaPath`, `profilePhotoPath`) that is stable across retries of the
/// same item — so a 409 means a previous attempt at *this same item* already
/// put *these same bytes* at *this same path*. That is the outcome the caller
/// wanted; reporting it as an error is what made a whole batch un-retryable
/// after a timeout, since `.timeout()` stops waiting without cancelling the
/// request that is still in flight.
///
/// Deliberately not `upsert: true`: there is no UPDATE policy on
/// `storage.objects` for either prefix (replacing a file is always a new
/// upload plus a delete of the old object), so an overwrite would be refused
/// by RLS — and there is nothing to overwrite anyway, the content is identical.
Future<void> uploadTolerant(
  SupabaseClient client, {
  required String bucket,
  required String path,
  required Uint8List bytes,
}) async {
  try {
    await client.storage
        .from(bucket)
        .uploadBinary(path, bytes)
        .timeout(networkTimeout);
  } on StorageException catch (e) {
    if (e.statusCode != '409') rethrow;
  }
}
