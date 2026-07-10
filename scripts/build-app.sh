#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="PDFConverter"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
BUILD_DIR="$PROJECT_DIR/.build/release"
VERSION="${1:-1.0}"
RELEASE=0
for arg in "$@"; do
    [ "$arg" = "--release" ] && RELEASE=1
done

echo "Building $APP_NAME..."
cd "$PROJECT_DIR"
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/PDFConverter.icns" "$APP_BUNDLE/Contents/Resources/PDFConverter.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PDFConverter</string>
    <key>CFBundleIdentifier</key>
    <string>com.dimitrimann.pdfconverter</string>
    <key>CFBundleName</key>
    <string>PDF Converter</string>
    <key>CFBundleDisplayName</key>
    <string>PDF Converter</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>PDFConverter</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [ "$RELEASE" = "1" ]; then
    SIGN_IDENTITY="Developer ID Application: Dimitri Mann (CYK4F5SZTP)"
    echo "Signing with Developer ID (hardened runtime)..."
    codesign -s "$SIGN_IDENTITY" --force --options runtime --timestamp \
        --identifier "com.dimitrimann.pdfconverter" "$APP_BUNDLE"

    echo "Submitting for notarization..."
    NOTARIZE_ZIP="$PROJECT_DIR/$APP_NAME-notarize.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "MeetingScribe-notary" --wait
    rm "$NOTARIZE_ZIP"

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_BUNDLE"

    RELEASE_ZIP="$PROJECT_DIR/PDFConverter-$VERSION.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$RELEASE_ZIP"
    echo ""
    echo "Done: $APP_BUNDLE (notarized)"
    echo "Release zip: $RELEASE_ZIP"
else
    # Ad-hoc sign (local development)
    codesign -s - --force "$APP_BUNDLE"
    echo ""
    echo "Done: $APP_BUNDLE"
    echo "Run with: open \"$APP_BUNDLE\""
fi
