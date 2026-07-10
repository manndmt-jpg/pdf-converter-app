#!/bin/bash
set -e

# Usage: ./scripts/release.sh <version>
# Builds + notarizes, EdDSA-signs the zip, regenerates appcast.xml,
# uploads to the VPS (Sparkle feed) and creates a GitHub release.

if [ -z "$1" ]; then
    echo "Usage: ./scripts/release.sh <version>   e.g. 1.1"
    exit 1
fi
VERSION="$1"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Error: Version must be semver (e.g., 1.1 or 1.1.2)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RELEASES_DIR="$PROJECT_DIR/releases"
ZIP_NAME="PDFConverter-${VERSION}.zip"
ZIP_PATH="$RELEASES_DIR/$ZIP_NAME"
SIGN_TOOL="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
APPCAST_PATH="$RELEASES_DIR/appcast.xml"
DOWNLOAD_BASE="https://d-mann.dev/pdfconverter"
VPS_DEST="dev@91.99.110.175:/home/dev/Projects/pdfconverter-releases/"

echo "=== Release PDFConverter v${VERSION} ==="

echo ""
echo "1. Building + notarizing..."
"$SCRIPT_DIR/build-app.sh" "$VERSION" --release

echo ""
echo "2. Moving zip to releases/..."
mkdir -p "$RELEASES_DIR"
mv "$PROJECT_DIR/PDFConverter-$VERSION.zip" "$ZIP_PATH"
ZIP_SIZE=$(stat -f%z "$ZIP_PATH")
echo "   $ZIP_PATH ($ZIP_SIZE bytes)"

echo ""
echo "3. Signing zip with EdDSA..."
if [ ! -f "$SIGN_TOOL" ]; then
    echo "Error: sign_update not found at $SIGN_TOOL. Run 'swift build' first."
    exit 1
fi
SIGN_OUTPUT=$("$SIGN_TOOL" "$ZIP_PATH" 2>&1)
SIGNATURE=$(echo "$SIGN_OUTPUT" | grep 'sparkle:edSignature=' | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')
LENGTH=$(echo "$SIGN_OUTPUT" | grep 'length=' | sed 's/.*length="\([^"]*\)".*/\1/')
if [ -z "$SIGNATURE" ]; then
    echo "Error: Failed to get EdDSA signature. Raw output:"
    echo "$SIGN_OUTPUT"
    exit 1
fi
echo "   Signature: ${SIGNATURE:0:20}..."

echo ""
echo "4. Generating appcast.xml..."
PUB_DATE=$(date -R)

RELEASE_NOTES_FILE="$PROJECT_DIR/RELEASE_NOTES.md"
DESCRIPTION_BLOCK=""
if [ -f "$RELEASE_NOTES_FILE" ]; then
    NOTES_HTML=$(cat "$RELEASE_NOTES_FILE" | \
        sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | \
        sed 's/^### \(.*\)/<h3>\1<\/h3>/' | \
        sed 's/^## \(.*\)/<h2>\1<\/h2>/' | \
        sed 's/^# \(.*\)/<h1>\1<\/h1>/' | \
        sed 's/^\* \(.*\)/<li>\1<\/li>/' | \
        sed 's/^- \(.*\)/<li>\1<\/li>/' | \
        sed 's/\*\*\([^*]*\)\*\*/<b>\1<\/b>/g' | \
        tr '\n' ' ' | \
        sed 's/<\/li> <li>/<\/li><li>/g')
    DESCRIPTION_BLOCK="      <description><![CDATA[${NOTES_HTML}]]></description>"
    echo "   Found release notes: $RELEASE_NOTES_FILE"
fi

NEW_ITEM="    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
${DESCRIPTION_BLOCK}
      <enclosure
        url=\"${DOWNLOAD_BASE}/${ZIP_NAME}\"
        sparkle:edSignature=\"${SIGNATURE}\"
        length=\"${LENGTH}\"
        type=\"application/octet-stream\"
      />
    </item>"

PREV_ITEMS=""
if [ -f "$APPCAST_PATH" ]; then
    PREV_ITEMS=$(awk '/<item>/{found=1; block=""} found{block=block $0 "\n"} /<\/item>/{if(count<2){printf "%s", block; count++}; found=0}' "$APPCAST_PATH")
fi

cat > "$APPCAST_PATH" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>PDF Converter Updates</title>
    <link>${DOWNLOAD_BASE}/appcast.xml</link>
    <description>Most recent changes with links to updates.</description>
    <language>en</language>
${NEW_ITEM}
${PREV_ITEMS}
  </channel>
</rss>
EOF
echo "   Created: $APPCAST_PATH"

echo ""
echo "5. Uploading to VPS..."
scp "$ZIP_PATH" "$APPCAST_PATH" "$VPS_DEST"
echo "   Live at: ${DOWNLOAD_BASE}/${ZIP_NAME}"

echo ""
echo "6. GitHub release..."
if gh release view "v${VERSION}" > /dev/null 2>&1; then
    echo "   Release v${VERSION} already exists, uploading asset..."
    gh release upload "v${VERSION}" "$ZIP_PATH" --clobber
else
    NOTES_ARG=""
    [ -f "$RELEASE_NOTES_FILE" ] && NOTES_ARG="--notes-file $RELEASE_NOTES_FILE"
    gh release create "v${VERSION}" "$ZIP_PATH" --title "PDF Converter ${VERSION}" $NOTES_ARG
fi

echo ""
echo "=== Release v${VERSION} done ==="
echo "Sparkle feed:    ${DOWNLOAD_BASE}/appcast.xml"
echo "Direct download: ${DOWNLOAD_BASE}/${ZIP_NAME}"
