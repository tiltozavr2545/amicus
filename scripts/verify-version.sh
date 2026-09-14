#!/bin/sh
set -eu

base_ref=${BASE_REF:?BASE_REF must point to the PR base commit}

read_version() {
	awk '/^version:[[:space:]]/ { print $2; exit }' "$@"
}

base_version=$(git show "$base_ref:app/pubspec.yaml" | awk '/^version:[[:space:]]/ { print $2; exit }')
current_version=$(read_version app/pubspec.yaml)

if [ -z "$base_version" ] || [ -z "$current_version" ]; then
	echo "Could not read the app version from pubspec.yaml" >&2
	exit 1
fi

base_name=${base_version%+*}
current_name=${current_version%+*}
base_code=${base_version##*+}
current_code=${current_version##*+}

if [ "$base_name" = "$base_version" ] || [ "$current_name" = "$current_version" ]; then
	echo "Versions must use the name+build format, for example 0.3.1+4" >&2
	exit 1
fi

# versionName (the "0.18.8" part) is a display string only - neither Google
# Play nor App Store requires it to change between releases; both platforms
# key on the build number alone (versionCode / CFBundleVersion). So this only
# rejects a regression (going backwards), the same freedom the App Store
# side already has of shipping several builds under one marketing version.
if ! printf '%s\n' "$base_name" "$current_name" | awk -F. '
function valid(v) { return v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ }
NR == 1 { if (!valid($0)) exit 2; base = $0; next }
NR == 2 {
  if (!valid($0)) exit 2
  split(base, b); split($0, c)
  if (c[1] < b[1] || (c[1] == b[1] && c[2] < b[2]) ||
      (c[1] == b[1] && c[2] == b[2] && c[3] < b[3])) exit 1
  exit 0
}
'; then
	echo "versionName must not decrease: $base_name -> $current_name" >&2
	exit 1
fi

case "$base_code:$current_code" in
	*[!0-9:]*|:*)
		echo "PR version bump required: versionCode must be a positive integer" >&2
		exit 1
		;;
esac

if [ "$current_code" -le "$base_code" ]; then
	echo "PR version bump required: versionCode must increase from $base_code to $current_code" >&2
	exit 1
fi

printf '%s\n' "Version check passed: $base_version -> $current_version"
