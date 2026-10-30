#!/bin/bash
set -euo pipefail

if [[ $# != 1 ]]; then
    echo "Usage: /bin/bash scripts/sign-app.sh <app bundle>" >&2
    exit 1
fi

app="$1"
identity="${CODESIGN_IDENTITY:-}"
keychain="${CODESIGN_KEYCHAIN:-}"
directory="${GITHUB_NOTIFY_SIGNING_DIR:-$HOME/Library/Application Support/github-notify/signing}"
local_signing=false

if [[ -z "$identity" && -e "$directory" ]]; then
    if [[ ! -f "$directory/identity.sha1" || ! -f "$directory/keychain-password" || ! -f "$directory/signing.keychain-db" ]]; then
        echo "Local signing setup is incomplete at $directory. Refusing to fall back to ad-hoc signing." >&2
        exit 1
    fi
    identity="$(cat "$directory/identity.sha1")"
    if [[ ! "$identity" =~ ^[A-Fa-f0-9]{40}$ ]]; then
        echo "The local signing identity fingerprint is invalid." >&2
        exit 1
    fi
    keychain="$directory/signing.keychain-db"
    password="$(cat "$directory/keychain-password")"
    /usr/bin/security unlock-keychain -p "$password" "$keychain"
    local_signing=true
fi

identity="${identity:--}"
options=(--force --sign "$identity")
if [[ -n "$keychain" ]]; then options+=(--keychain "$keychain"); fi
if [[ "$identity" == - ]]; then
    echo "Using ad-hoc signing. For stable Keychain access across rebuilds, run make setup-signing." >&2
elif [[ "$local_signing" == true ]]; then
    options+=(--options runtime --timestamp=none)
else
    options+=(--options runtime --timestamp)
fi

/usr/bin/codesign "${options[@]}" "$app"
/usr/bin/codesign --verify --strict "$app"
