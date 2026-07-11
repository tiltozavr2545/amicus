SHELL := /bin/sh

APP_DIR := app
# Keep hooks independent of the interactive shell PATH. Override this when
# Flutter is installed elsewhere: make FLUTTER=/path/to/flutter verify
FLUTTER ?= $(HOME)/development/flutter/bin/flutter
DART ?= $(HOME)/development/flutter/bin/dart
BASE_REF ?= origin/main

.PHONY: help deps format-check analyze test verify verify-version build-android pre-commit pre-push install-hooks uninstall-hooks

help:
	@printf '%s\n' \
		'make verify          Run dependency, format, analysis, and test checks' \
		'make verify-version  Verify a version bump against BASE_REF (default: origin/main)' \
		'make build-android   Build the release Android App Bundle' \
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

build-android:
	cd $(APP_DIR) && $(FLUTTER) build appbundle --release \
		--dart-define=SUPABASE_URL=https://example.invalid \
		--dart-define=SUPABASE_ANON_KEY=ci-placeholder

pre-commit: verify

pre-push: verify verify-version build-android

install-hooks:
	git config core.hooksPath .githooks
	@printf '%s\n' 'Repository hooks enabled via .githooks'

uninstall-hooks:
	git config --unset core.hooksPath || true
	@printf '%s\n' 'Repository hooks disabled'
