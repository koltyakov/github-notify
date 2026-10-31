#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
version="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
arch="${ARCH:-arm64}"

if [[ ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
    echo "VERSION must contain only letters, numbers, dots, underscores, plus signs, or hyphens." >&2
    exit 1
fi
# Preserve the complete Git description for About, but keep Apple's version fields numeric.
bundle_version=0.0.0
if [[ "$version" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+)([-+].*)?$ ]]; then
    bundle_version="${BASH_REMATCH[1]}"
fi
case "$arch" in
    arm64|x86_64)
        swift build -c release --arch "$arch"
        bin_path="$(swift build -c release --arch "$arch" --show-bin-path)"
        binary="$bin_path/github-notify"
        ;;
    universal)
        # Build separately so universal bundles also work with Command Line Tools alone.
        swift build -c release --arch arm64
        arm_path="$(swift build -c release --arch arm64 --show-bin-path)"
        swift build -c release --arch x86_64
        intel_path="$(swift build -c release --arch x86_64 --show-bin-path)"
        binary=".build/github-notify-universal"
        /usr/bin/lipo -create "$arm_path/github-notify" "$intel_path/github-notify" -output "$binary"
        ;;
    *) echo "ARCH must be arm64, x86_64, or universal" >&2; exit 1 ;;
esac

app="dist/GitHub Notify.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist/staging
cp "$binary" "$app/Contents/MacOS/github-notify"
/bin/bash scripts/build-credential-helper.sh "$arch" "$app/Contents/Helpers/github-notify-credentials"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp assets/icon.png "$app/Contents/Resources/AppLogo.png"
swift scripts/generate-status-icons.swift assets/icon.png "$app/Contents/Resources"
cp packaging/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $bundle_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $bundle_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :GitHubNotifyVersion $version" "$app/Contents/Info.plist"

# Generate the app icon using only tools shipped with macOS.
iconset=".build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" assets/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    /usr/bin/sips -z "$double" "$double" assets/icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

/bin/bash scripts/sign-app.sh "$app"
/usr/bin/ditto "$app" "dist/staging/GitHub Notify.app"
ln -sfn /Applications dist/staging/Applications
echo "Built $app $version for $arch"
