#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
version="${VERSION:-0.0.0}"
arch="${ARCH:-arm64}"
identity="${CODESIGN_IDENTITY:--}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must contain three numbers, for example 1.2.3" >&2
    exit 1
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
cp LICENSE "$app/Contents/Resources/LICENSE"
for state in base notice warn error; do
    cp "assets/tray/$state.png" "$app/Contents/Resources/status-$state.png"
done
cp packaging/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"

# Generate the app icon using only tools shipped with macOS.
iconset=".build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" assets/icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    /usr/bin/sips -z "$double" "$double" assets/icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

sign_options=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
    sign_options+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${sign_options[@]}" "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/ditto "$app" "dist/staging/GitHub Notify.app"
ln -sfn /Applications dist/staging/Applications
echo "Built $app for $arch"
