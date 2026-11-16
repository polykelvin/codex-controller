#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/dist/Codex Controller.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$PWD/.build/module-cache"
/usr/bin/swiftc -O -module-cache-path "$PWD/.build/module-cache" -framework AppKit -framework Security Sources/main.swift -o "$PWD/.build/CodexController"
/bin/mv -f "$PWD/.build/CodexController" "$APP/Contents/MacOS/CodexController"
/usr/bin/ditto backend "$APP/Contents/Resources/backend"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.kelvin.codex-controller</string>
<key>CFBundleExecutable</key><string>CodexController</string>
<key>CFBundleName</key><string>Codex Controller</string>
<key>CFBundleDisplayName</key><string>Codex Controller</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
