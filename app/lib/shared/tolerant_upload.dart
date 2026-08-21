import 'dart:io';
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
}) {
  return _tolerant(() => client.storage.from(bucket).uploadBinary(path, bytes));
}

/// Reads [file] and uploads it, with the same 409 tolerance.
///
/// Deliberately NOT `storage.upload(path, File)`, which looks like the
/// streaming call and is not one: in storage_client 2.6.0 that path runs
/// `file.readAsBytesSync()` (`src/fetch.dart`, `_handleFileRequest`) and then
/// hands the result to `MultipartFile.fromBytes` — the very same bytes in
/// memory as `uploadBinary`, except read *synchronously* on the calling
/// isolate. For a 100 MB clip that is a frozen UI, so it would be strictly
/// worse than what it replaced.
///
/// The win is therefore in *when* the read happens, not in avoiding it. The
/// clip is materialised here, during its own upload, and released after —
/// instead of being read at pick time and held for the whole composer
/// session alongside up to 19 others.
Future<void> uploadTolerantFile(
  SupabaseClient client, {
  required String bucket,
  required String path,
  required File file,
}) async {
  final bytes = await file.readAsBytes();
  await uploadTolerant(client, bucket: bucket, path: path, bytes: bytes);
}

Future<void> _tolerant(Future<String> Function() upload) async {
  try {
    await upload().timeout(networkTimeout);
  } on StorageException catch (e) {
    if (e.statusCode != '409') rethrow;
  }
}
