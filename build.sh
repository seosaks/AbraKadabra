#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="АбраКадабра.app"
executable="$app/Contents/MacOS/AbraKadabra"
minimum=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' Info.plist)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for cpu in arm64 x86_64; do
    xcrun swiftc -O -target "${cpu}-apple-macos${minimum}" \
        -module-cache-path "${TMPDIR:-/tmp}/abrakadabra-modules" \
        Sources/*.swift -o "$work/$cpu"
done

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp "АбраКадабра — авторский знак.png" "$app/Contents/Resources/MenuIcon.png"
cp Info.plist "$app/Contents/Info.plist"
xcrun lipo -create "$work/arm64" "$work/x86_64" -output "$executable"
codesign --force --sign - --identifier local.oleg.AbraKadabra "$app"
codesign --verify --strict "$app"
architectures=$(xcrun lipo -archs "$executable")
for cpu in arm64 x86_64; do
    [[ " $architectures " == *" $cpu "* ]] || exit 1
done
