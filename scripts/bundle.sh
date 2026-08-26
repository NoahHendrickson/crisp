#!/bin/zsh
# Build Crisp and wrap it in a signed .app bundle.
#
#   ./scripts/bundle.sh            → build/Crisp Dev.app  (com.noey.crisp.dev)
#   ./scripts/bundle.sh --release  → build/Crisp.app      (com.noey.crisp)
#
# The two variants have separate bundle identifiers, so each keeps its own
# Screen Recording grant and they can be installed side by side: use the
# released Crisp daily while hacking on Crisp Dev.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="0.1.0"

if [[ "${1:-}" == "--release" ]]; then
    APP_NAME="Crisp"
    BUNDLE_ID="com.noey.crisp"
    ICON="assets/AppIcon.icns"
else
    APP_NAME="Crisp Dev"
    BUNDLE_ID="com.noey.crisp.dev"
    ICON="assets/AppIcon-Dev.icns"
fi

swift build -c release

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Crisp "$APP/Contents/MacOS/Crisp"
# SwiftPM resource bundle (fonts, icons) — Bundle.module looks in Contents/Resources.
cp -R .build/release/Crisp_Crisp.bundle "$APP/Contents/Resources/"
if [[ -f "$ICON" ]]; then
    cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Crisp</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Crisp lists your Google Chrome tabs and switches to the one you pick so it can be recorded.</string>
</dict>
</plist>
PLIST

# Prefer a real signing identity (stable across rebuilds, so the Screen
# Recording grant persists). Fall back to ad-hoc, which requires re-granting
# the permission after every rebuild.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application|Crisp Dev Signing/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
    echo "Signing with: $IDENTITY"
    codesign --force --options runtime --entitlements assets/Crisp.entitlements --sign "$IDENTITY" "$APP"
else
    echo "Signing ad-hoc (no identity found — permission re-grant needed after each rebuild)"
    codesign --force --entitlements assets/Crisp.entitlements --sign - "$APP"
fi

echo "Built $APP ($BUNDLE_ID, v$VERSION)"
echo "Run with: open \"$APP\""
