#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="АбраКадабра.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp "АбраКадабра — авторский знак.png" "$app/Contents/Resources/MenuIcon.png"
cp Info.plist "$app/Contents/Info.plist"
swiftc -O -target "$(uname -m)-apple-macos13.0" -module-cache-path "${TMPDIR:-/tmp}/abrakadabra-modules" Sources/*.swift -o "$app/Contents/MacOS/AbraKadabra"
codesign --force --sign - --identifier local.oleg.AbraKadabra "$app"
