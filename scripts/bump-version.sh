#!/bin/sh
set -eu

pubspec="app/pubspec.yaml"

usage() {
	cat >&2 <<'EOF'
Usage: scripts/bump-version.sh <build|patch|minor|major>

  build   Keep versionName the same, bump only versionCode (the build
          number). Valid on its own for a Play Store / App Store release —
          neither store requires versionName to change between uploads.
  patch   Bump versionName's patch component (0.18.8 -> 0.18.9) and
          versionCode.
  minor   Bump versionName's minor component, reset patch to 0
          (0.18.8 -> 0.19.0), and bump versionCode.
  major   Bump versionName's major component, reset minor and patch to 0
          (0.18.8 -> 1.0.0), and bump versionCode.

versionCode always increases by 1 — Play Store requires every upload to
carry a strictly higher versionCode than any before it, in any track.
EOF
	exit 1
}

[ $# -eq 1 ] || usage

case "$1" in
	build | patch | minor | major) ;;
	*) usage ;;
esac
kind="$1"

[ -f "$pubspec" ] || {
	echo "Error: $pubspec not found — run this from the repository root." >&2
	exit 1
}

current_version=$(awk '/^version:[[:space:]]/ { print $2; exit }' "$pubspec")
[ -n "$current_version" ] || {
	echo "Error: could not read 'version:' from $pubspec" >&2
	exit 1
}

current_name=${current_version%+*}
current_code=${current_version##*+}

if [ "$current_name" = "$current_version" ] || [ "$current_code" = "$current_version" ]; then
	echo "Error: $pubspec's version must use the name+build format, e.g. 0.18.8+61 (found: $current_version)" >&2
	exit 1
fi

case "$current_name" in
	*[!0-9.]* | '' )
		echo "Error: versionName must be X.Y.Z (found: $current_name)" >&2
		exit 1
		;;
esac

major=$(printf '%s' "$current_name" | cut -d. -f1)
minor=$(printf '%s' "$current_name" | cut -d. -f2)
patch=$(printf '%s' "$current_name" | cut -d. -f3)

case "$major:$minor:$patch" in
	*[!0-9:]*)
		echo "Error: versionName must be X.Y.Z with three numeric parts (found: $current_name)" >&2
		exit 1
		;;
esac

case "$kind" in
	build) ;;
	patch) patch=$((patch + 1)) ;;
	minor) minor=$((minor + 1)); patch=0 ;;
	major) major=$((major + 1)); minor=0; patch=0 ;;
esac

new_name="$major.$minor.$patch"
new_code=$((current_code + 1))
new_version="$new_name+$new_code"

# BSD sed (macOS) needs -i '' ; GNU sed needs -i without an argument. Try BSD
# form first and fall back, rather than branching on `uname` — the failure
# mode (a literal `''` argument file) is exactly what -i '' avoids, and GNU
# sed's -i accepts a following script argument as the suffix if given one, so
# guessing wrong is not silently harmless.
if sed --version >/dev/null 2>&1; then
	sed -i "s/^version: $current_version\$/version: $new_version/" "$pubspec"
else
	sed -i '' "s/^version: $current_version\$/version: $new_version/" "$pubspec"
fi

printf '%s\n' "Bumped $pubspec: $current_version -> $new_version"
