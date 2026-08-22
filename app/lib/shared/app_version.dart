import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// What this install reports about itself, normalised for the shape
/// `device_tokens.app_version` / `.app_build` accept.
///
/// Both are nullable because both can be, and a device that cannot describe
/// itself must still be able to register for push. That is the whole reason
/// this normalisation exists rather than passing `PackageInfo` straight
/// through: those columns carry a CHECK constraint, and a constraint violation
/// on a fire-and-forget upsert would fail *device registration itself*,
/// silently, leaving the user with no notifications at all. Far better to
/// store a null the server already reads as "older than anything known" (see
/// migration 20260822120000) than to risk that.
class AppVersion {
  const AppVersion({this.name, this.build});

  /// `versionName`, e.g. `0.16.4` — only ever displayed or eyeballed, never
  /// compared. String-comparing `0.9.0` against `0.16.0` is the classic way to
  /// get this wrong.
  final String? name;

  /// `versionCode`, e.g. `38` — monotonic, and what every "is this newer"
  /// decision is actually made on.
  final int? build;

  /// Mirrors `device_tokens_app_version_format`. Anything else becomes null
  /// rather than a rejected insert.
  static final _namePattern = RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$');

  factory AppVersion.fromPackageInfo(PackageInfo info) {
    final build = int.tryParse(info.buildNumber);
    return AppVersion(
      name: _namePattern.hasMatch(info.version) ? info.version : null,
      // Mirrors `device_tokens_app_build_positive`.
      build: (build != null && build > 0) ? build : null,
    );
  }
}

final appVersionProvider = FutureProvider<AppVersion>((ref) async {
  return AppVersion.fromPackageInfo(await PackageInfo.fromPlatform());
});
