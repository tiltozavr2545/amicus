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

# Both build numbers are checked before either is compared, and what is
# ALLOWED is enumerated rather than guessed at.
#
# `[ "$x" -le "$y" ]` on anything that is not an integer is not a comparison
# that comes out false — it is a usage error: `[` writes "Illegal number" to
# stderr and returns 2. Inside an `if` condition that reads as "false", and
# `set -e` does not apply there either, so the script sailed straight past its
# own gate and printed "Version check passed".
#
# `version: 0.18.13+` did exactly that. `${v##*+}` gives the empty string, and
# the previous pattern (`*[!0-9:]*|:*` over "$base_code:$current_code") did not
# match it: no non-digits anywhere, and the colon is not leading. So the one
# check that guarantees every PR carries a build number approved a version
# that had none.
for code in "$base_code" "$current_code"; do
	case "$code" in
		'' | *[!0-9]*)
			echo "PR version bump required: versionCode must be a positive integer, got '$code'" >&2
			exit 1
			;;
	esac
done

# versionName (the "0.18.8" part) is a display string only - neither Google
# Play nor App Store requires it to change between releases; both platforms
# key on the build number alone (versionCode / CFBundleVersion). So this only
# rejects a regression (going backwards), the same freedom the App Store
# side already has of shipping several builds under one marketing version.
#
# Two failures, told apart: awk exits 1 for a version that went backwards and
# 2 for one that is not major.minor.patch at all. Both used to print "must not
# decrease", which is the wrong sentence for the second — and the second is
# how a version with more than one `+` arrives here, since `${v%+*}` leaves
# `1.0.0+1` as the "name" for `1.0.0+1+2`.
name_status=0
printf '%s\n' "$base_name" "$current_name" | awk -F. '
function valid(v) { return v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ }
NR == 1 { if (!valid($0)) exit 2; base = $0; next }
NR == 2 {
  if (!valid($0)) exit 2
  split(base, b); split($0, c)
  if (c[1] < b[1] || (c[1] == b[1] && c[2] < b[2]) ||
      (c[1] == b[1] && c[2] == b[2] && c[3] < b[3])) exit 1
  exit 0
}
' || name_status=$?

case "$name_status" in
	0) ;;
	1)
		echo "versionName must not decrease: $base_name -> $current_name" >&2
		exit 1
		;;
	*)
		echo "versionName must be major.minor.patch, for example 0.3.1: '$base_name' -> '$current_name'" >&2
		exit 1
		;;
esac

if [ "$current_code" -le "$base_code" ]; then
	echo "PR version bump required: versionCode must increase from $base_code to $current_code" >&2
	exit 1
fi

printf '%s\n' "Version check passed: $base_version -> $current_version"
