#!/bin/bash
set -euo pipefail
umask 077
scripts="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Local app signing requires macOS." >&2
    exit 1
fi

directory="${GITHUB_NOTIFY_SIGNING_DIR:-$HOME/Library/Application Support/github-notify/signing}"
keychain="$directory/signing.keychain-db"
password_file="$directory/keychain-password"
certificate="$directory/certificate.pem"
identity_file="$directory/identity.sha1"

if [[ -f "$identity_file" && -f "$password_file" && -f "$keychain" && -f "$certificate" ]]; then
    password="$(cat "$password_file")"
    identity="$(cat "$identity_file")"
    /usr/bin/security unlock-keychain -p "$password" "$keychain"
    swift -suppress-warnings "$scripts/register-signing-keychain.swift" "$keychain"
    if /usr/bin/security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -Fq "$identity"; then
        echo "GitHub Notify local signing is already configured."
        exit 0
    fi
    echo "The existing local signing identity is not valid. Check its certificate trust or expiration in Keychain Access." >&2
    exit 1
fi

if [[ -e "$keychain" || -e "$password_file" || -e "$certificate" || -e "$identity_file" ]]; then
    echo "Local signing setup is incomplete at $directory. Existing signing files were not overwritten." >&2
    exit 1
fi

if [[ -e "$directory" ]]; then
    echo "Use a new dedicated directory for signing. Existing directory was not changed: $directory" >&2
    exit 1
fi

mkdir -p "$directory"
chmod 700 "$directory"
work="$(mktemp -d "${TMPDIR:-/tmp}/github-notify-signing.XXXXXX")"
cleanup() {
    rm -f "$work/key.pem" "$work/certificate.cnf" "$work/identity.p12"
    rmdir "$work"
}
trap cleanup EXIT

cat > "$work/certificate.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = name
x509_extensions = signing
[name]
CN = GitHub Notify Local Development
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

/usr/bin/openssl rand -hex 32 > "$password_file"
password="$(cat "$password_file")"
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
    -config "$work/certificate.cnf" -keyout "$work/key.pem" -out "$certificate" 2>/dev/null
export GITHUB_NOTIFY_P12_PASSWORD="$(/usr/bin/openssl rand -hex 32)"
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$certificate" \
    -name "GitHub Notify Local Development" -out "$work/identity.p12" -passout env:GITHUB_NOTIFY_P12_PASSWORD

# This isolated Keychain contains only the new signing key, never the GitHub token.
/usr/bin/security create-keychain -p "$password" "$keychain"
chmod 600 "$keychain"
/usr/bin/security set-keychain-settings -lut 300 "$keychain"
/usr/bin/security unlock-keychain -p "$password" "$keychain"
/usr/bin/security import "$work/identity.p12" -k "$keychain" -P "$GITHUB_NOTIFY_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
unset GITHUB_NOTIFY_P12_PASSWORD
/usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
swift -suppress-warnings "$scripts/register-signing-keychain.swift" "$keychain"

echo "macOS may request approval to trust the local certificate for code signing only."
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$certificate"
identity="$(/usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')"
if ! /usr/bin/security find-identity -v -p codesigning "$keychain" | /usr/bin/grep -Fq "$identity"; then
    echo "macOS did not accept the signing identity. No GitHub-token permissions were changed." >&2
    exit 1
fi
printf '%s\n' "$identity" > "$identity_file"
echo "Local signing configured. Future make app/install builds will reuse this identity."
echo "After installing, approve GitHub Notify with Always Allow once if Keychain asks."
