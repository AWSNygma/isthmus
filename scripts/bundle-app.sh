#!/usr/bin/env bash
# Build Isthmus.app (arm64) into dist/.
#
#   scripts/bundle-app.sh            ad-hoc signed, for local use
#   SIGN_IDENTITY="Developer ID Application: …" scripts/bundle-app.sh
#                                    hardened runtime + Developer ID signature
#   NOTARIZE_PROFILE=isthmus …       also notarize and staple (needs
#                                    `xcrun notarytool store-credentials isthmus` first)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/IsthmusKit/Engine.swift)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DIST=dist
APP="$DIST/Isthmus.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> swift build (release, arm64)"
swift build -c release --arch arm64 --product IsthmusApp
swift build -c release --arch arm64 --product isthmus
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/IsthmusApp" "$APP/Contents/MacOS/Isthmus"
cp "$BIN/isthmus" "$APP/Contents/Helpers/isthmus"
cp -R "$BIN/Isthmus_IsthmusKit.bundle" "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/" 2>/dev/null || true

echo "==> icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Isthmus</string>
  <key>CFBundleDisplayName</key><string>Isthmus</string>
  <key>CFBundleIdentifier</key><string>io.github.awsnygma.isthmus</string>
  <key>CFBundleExecutable</key><string>Isthmus</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0-or-later. Wine is LGPL-2.1.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Windows Program</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.microsoft.windows-executable</string>
        <string>com.microsoft.msi-installer</string>
        <string>com.microsoft.windows-batch</string>
        <string>com.microsoft.windows-shortcut</string>
      </array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.microsoft.windows-executable</string>
      <key>UTTypeDescription</key><string>Windows Program</string>
      <key>UTTypeConformsTo</key><array><string>public.executable</string><string>public.data</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>exe</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.microsoft.msi-installer</string>
      <key>UTTypeDescription</key><string>Windows Installer Package</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>msi</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.microsoft.windows-batch</string>
      <key>UTTypeDescription</key><string>Windows Batch File</string>
      <key>UTTypeConformsTo</key><array><string>public.script</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>bat</string><string>cmd</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>com.microsoft.windows-shortcut</string>
      <key>UTTypeDescription</key><string>Windows Shortcut</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>lnk</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> sign ($SIGN_IDENTITY)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP/Contents/Helpers/isthmus"
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --entitlements scripts/Isthmus.entitlements --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/isthmus"
  codesign --force --options runtime --timestamp --entitlements scripts/Isthmus.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "==> package"
ZIP="$DIST/Isthmus-$VERSION.zip"
DMG="$DIST/Isthmus-$VERSION.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Isthmus $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
[[ "$SIGN_IDENTITY" != "-" ]] && codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [[ -n "${NOTARIZE_PROFILE:-}" ]]; then
  echo "==> notarize"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARIZE_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
fi

shasum -a 256 "$ZIP" "$DMG" | tee "$DIST/SHA256SUMS"
echo "==> done: $APP"
