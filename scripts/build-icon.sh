#!/usr/bin/env bash
#
# Generate AppIcon.icns from Resources/AppIcon.svg.
#
# Run manually after editing the SVG. Both the SVG and the .icns
# are committed to git.
#
# Requires: rsvg-convert (brew install librsvg), iconutil (built into macOS).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE_SVG="$REPO_ROOT/Resources/AppIcon.svg"
BUILD_DIR="$REPO_ROOT/build/icon"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
OUTPUT_ICNS="$BUILD_DIR/AppIcon.icns"
DEST_ICNS="$REPO_ROOT/Sources/LiteMail/Resources/AppIcon.icns"

# 1. Verify dependencies
if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "ERROR: rsvg-convert not found." >&2
    echo "Install with: brew install librsvg" >&2
    exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
    echo "ERROR: iconutil not found (should be built into macOS)." >&2
    exit 1
fi

if [ ! -f "$SOURCE_SVG" ]; then
    echo "ERROR: source SVG not found at $SOURCE_SVG" >&2
    exit 1
fi

# 2. Clean and recreate build dir
rm -rf "$BUILD_DIR"
mkdir -p "$ICONSET_DIR"

# 3. Render PNGs at all required sizes (Apple iconset spec)
# Format: filename:pixel_size
sizes=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)

echo "Rendering ${#sizes[@]} PNG variants from $SOURCE_SVG..."
for entry in "${sizes[@]}"; do
    filename="${entry%%:*}"
    size="${entry##*:}"
    rsvg-convert -w "$size" -h "$size" "$SOURCE_SVG" -o "$ICONSET_DIR/$filename"
done

# 4. Pack iconset into .icns
echo "Packing iconset into .icns..."
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"

# 5. Copy to bundled location
mkdir -p "$(dirname "$DEST_ICNS")"
cp "$OUTPUT_ICNS" "$DEST_ICNS"

size_kb=$(( $(stat -f%z "$DEST_ICNS") / 1024 ))
echo ""
echo "✓ Source:  $SOURCE_SVG"
echo "✓ Output:  $DEST_ICNS"
echo "✓ Size:    ${size_kb} KB"
