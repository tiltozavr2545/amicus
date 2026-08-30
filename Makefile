SHELL := /bin/sh

APP_DIR := app
# Keep hooks independent of the interactive shell PATH. Override this when
# Flutter is installed elsewhere: make FLUTTER=/path/to/flutter verify
FLUTTER ?= $(HOME)/development/flutter/bin/flutter
DART ?= $(HOME)/development/flutter/bin/dart
BASE_REF ?= origin/main

.PHONY: help deps format-check analyze test verify verify-version build-android build-ios release-ios pre-commit pre-push install-hooks uninstall-hooks

help:
	@printf '%s\n' \
		'make verify          Run dependency, format, analysis, and test checks' \
		'make verify-version  Verify a version bump against BASE_REF (default: origin/main)' \
		'make build-android   Build the release Android App Bundle' \
		'make build-ios       Compile-check the iOS release build (unsigned)' \
		'make release-ios     Build a signed IPA for TestFlight/App Store upload' \
		'make pre-commit      Run fast checks used by the pre-commit hook' \
		'make pre-push        Run checks plus the Android release build' \
		'make install-hooks   Enable the repository-managed Git hooks' \
		'make uninstall-hooks Disable the repository-managed Git hooks'

deps:
	cd $(APP_DIR) && $(FLUTTER) pub get --enforce-lockfile

format-check:
	cd $(APP_DIR) && $(DART) format --set-exit-if-changed .

analyze:
	cd $(APP_DIR) && $(FLUTTER) analyze

test:
	cd $(APP_DIR) && $(FLUTTER) test

verify: deps format-check analyze test

verify-version:
	BASE_REF="$(BASE_REF)" ./scripts/verify-version.sh

# -PallowDebugSigning=true: this target is a compile check, not a shippable
# build, so it opts in to the debug-key fallback that a release build otherwise
# refuses (see android/app/build.gradle.kts). Never add this flag to anything
# that produces an artifact for distribution.
build-android:
	cd $(APP_DIR) && $(FLUTTER) build appbundle --release \
		-PallowDebugSigning=true \
		--dart-define=SUPABASE_URL=https://example.invalid \
		--dart-define=SUPABASE_ANON_KEY=ci-placeholder

# --no-codesign: this target is a compile check, not a shippable build, so it
# skips signing/provisioning-profile requirements entirely (mirrors
# build-android's debug-signing fallback, but iOS has no such fallback for
# release builds). Never use this output for TestFlight/App Store — those
# still go through Xcode's Automatic signing, per docs/ios-deployment-guide.md.
build-ios:
	cd $(APP_DIR) && $(FLUTTER) build ios --release --no-codesign \
		--dart-define=SUPABASE_URL=https://example.invalid \
		--dart-define=SUPABASE_ANON_KEY=ci-placeholder

# Unlike build-ios, this is a real shippable artifact: signed via Automatic
# signing (ios/ExportOptions.plist) with the real app/.env, not placeholder
# credentials. Needs an Admin/Account Holder Apple ID signed into Xcode.
# Uploading the resulting IPA to App Store Connect is still a manual step
# (Transporter.app) — see docs/ios-deployment-guide.md.
release-ios:
	cd $(APP_DIR) && $(FLUTTER) build ipa --dart-define-from-file=.env \
		--export-options-plist=ios/ExportOptions.plist

pre-commit: verify

pre-push: verify build-android

install-hooks:
	git config core.hooksPath .githooks
	@printf '%s\n' 'Repository hooks enabled via .githooks'

uninstall-hooks:
	git config --unset core.hooksPath || true
	@printf '%s\n' 'Repository hooks disabled'
