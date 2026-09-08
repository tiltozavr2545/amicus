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

# Xcode Cloud silently overrides CFBundleVersion with its own internal
# counter ($CI_BUILD_NUMBER) regardless of what pubspec.yaml/Generated.xcconfig
# say - confirmed by testing (a pubspec bump to +58 still produced build "5",
# matching $CI_BUILD_NUMBER exactly). Rather than fight that, derive the
# actual build number from it, offset well clear of every build number ever
# uploaded locally (up to 57 as of this writing) so it can never collide.
# Bump the offset upward, never down, if history grows past it.
IOS_BUILD_NUMBER=$((CI_BUILD_NUMBER + 52))

# Same command as `make build-ios`, minus --no-codesign's placeholder
# --dart-define pair: this bakes the real DART_DEFINES into
# ios/Flutter/Generated.xcconfig and builds Flutter.framework/App.framework,
# which Xcode Cloud's own xcodebuild archive step then picks up through the
# project's existing xcconfig include chain. --no-codesign because signing
# and archiving are Xcode Cloud's job, not this script's.
flutter build ios --release --no-codesign --build-number="$IOS_BUILD_NUMBER" --dart-define-from-file=.env
