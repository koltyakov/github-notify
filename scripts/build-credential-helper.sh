#!/bin/bash
set -euo pipefail

if [[ $# != 2 ]]; then
    echo "Usage: /bin/bash scripts/build-credential-helper.sh <architecture> <output>" >&2
    exit 1
fi
cd "$(dirname "$0")/.."
arch="$1"
output="$2"
case "$arch" in
    arm64|x86_64) architectures=(-arch "$arch") ;;
    universal) architectures=(-arch arm64 -arch x86_64) ;;
    *) echo "Unsupported credential-helper architecture: $arch" >&2; exit 1 ;;
esac
source="Sources/GitHubNotifyCredentials/main.m"
compiler="$(/usr/bin/xcrun --find clang)"
sdk="$(/usr/bin/xcrun --show-sdk-path)"
# Cache independently of Swift/UI sources and the outer app version. The login
# Keychain's partition check needs this reader's code hash to survive app rebuilds.
key="$( { /usr/bin/shasum -a 256 "$source"; "$compiler" --version; printf '%s\n' "$arch" "$sdk" 'credential-helper-build-v3'; } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
cache="${GITHUB_NOTIFY_CREDENTIAL_CACHE_ROOT:-.build/credential-helper}/$key"
binary="$cache/github-notify-credentials"
if [[ ! -f "$binary" ]]; then
    mkdir -p "$cache"
    temporary="$binary.tmp.$$"
    trap 'rm -f "$temporary"' EXIT
    # A per-link UUID or temporary ad-hoc identifier would change the code hash
    # after a clean rebuild even when this source is unchanged.
    "$compiler" "${architectures[@]}" -isysroot "$sdk" -mmacosx-version-min=13.0 \
        -Os -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations -Wl,-no_adhoc_codesign,-no_uuid \
        -framework Foundation -framework Security "$source" -o "$temporary"
    mv "$temporary" "$binary"
fi
mkdir -p "$(dirname "$output")"
cp "$binary" "$output"
