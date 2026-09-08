#!/bin/sh
set -eu

# Xcode Cloud clones the repo and then runs `xcodebuild archive` on
# Runner.xcworkspace directly — it has no idea this is a Flutter project.
# Everything Flutter/CocoaPods normally does before a real build has to
# happen here, in ci_post_clone.sh, or the archive step fails.
#
# Pinned to the exact version this project's SDK constraint expects
# (app/pubspec.yaml: `sdk: ^3.8.1` -> Flutter 3.32.8 ships that Dart).
# Bump this only after bumping the pin in AGENTS.md/pubspec.yaml too.
FLUTTER_VERSION="3.32.8"
FLUTTER_HOME="$HOME/flutter"

if [ ! -d "$FLUTTER_HOME" ]; then
  git clone https://github.com/flutter/flutter.git -b "$FLUTTER_VERSION" --depth 1 "$FLUTTER_HOME"
fi
export PATH="$PATH:$FLUTTER_HOME/bin"

cd "$CI_PRIMARY_REPOSITORY_PATH/app"

# GoogleService-Info.plist is gitignored too (see docs/ios-deployment-guide.md
# prerequisites) — Xcode's project.pbxproj still expects it as a bundled
# resource, so a missing file fails the archive step. Reconstitute it from a
# base64-encoded Environment Variable (Xcode Cloud has no native "file"
# secret type, only key=value). Generate the value once with:
#   base64 -i ios/Runner/GoogleService-Info.plist | pbcopy
# and paste it into the workflow's Environment Variables as
# GOOGLE_SERVICE_INFO_PLIST_BASE64 (mark it Secret).
if [ -n "${GOOGLE_SERVICE_INFO_PLIST_BASE64:-}" ]; then
  echo "$GOOGLE_SERVICE_INFO_PLIST_BASE64" | base64 --decode > ios/Runner/GoogleService-Info.plist
fi

# .env is gitignored (holds Supabase secrets), so Xcode Cloud never clones
# it. Recreate it from this workflow's Environment Variables (App Store
# Connect -> Xcode Cloud -> workflow -> Environment Variables) so the build
# below keeps working unchanged from the local `make release-ios` path.
cat > .env <<ENVFILE
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
ENVFILE

flutter precache --ios
flutter pub get

# Xcode Cloud's own archive/upload pipeline unconditionally rewrites
# CFBundleVersion with its internal $CI_BUILD_NUMBER counter, regardless of
# whatever this script computes here - confirmed by testing two different
# ways (letting pubspec.yaml drive it, and passing --build-number explicitly
# with a safe offset); both were silently overridden to Xcode Cloud's raw
# counter anyway (see IMM-172). Nothing in ci_post_clone.sh can influence the
# final iOS build number, so it isn't worth trying to compute one here -
# --build-number is intentionally omitted; use whatever pubspec.yaml already
# has, same as `make build-ios` does locally.
#
# Practical risk: $CI_BUILD_NUMBER starts low (currently in the single
# digits) and grows only as fast as this workflow triggers builds - it would
# need dozens more runs before reaching the range of pre-Xcode-Cloud local
# build numbers (up to 57 as of this writing) and risking a collision. If
# that becomes a real concern, look for an actual Xcode Cloud setting to
# disable automatic versioning rather than trying to out-compute it again.
flutter build ios --release --no-codesign --dart-define-from-file=.env
