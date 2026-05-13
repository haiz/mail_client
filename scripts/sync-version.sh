#!/usr/bin/env bash
# Sync the version in VERSION to Info.plist (CFBundleShortVersionString + CFBundleVersion).
# Usage: ./scripts/sync-version.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

VERSION_FILE="$REPO_ROOT/VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
    echo "error: $VERSION_FILE not found" >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

if [[ -z "$VERSION" ]]; then
    echo "error: VERSION file is empty" >&2
    exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION '$VERSION' is not semver (X.Y.Z)" >&2
    exit 1
fi

# Returns 0 if file already contains the expected pattern, 1 otherwise.
report() {
    local path="$1" pattern="$2"
    if grep -qE "$pattern" "$path"; then
        echo "  $path — OK"
    else
        echo "  $path — FAILED to apply" >&2
        return 1
    fi
}

INFO_PLIST="$REPO_ROOT/Sources/LiteMail/Resources/Info.plist"

if [[ ! -f "$INFO_PLIST" ]]; then
    echo "error: $INFO_PLIST not found" >&2
    exit 1
fi

echo "Syncing version $VERSION..."

# Patch the <string> on the line AFTER <key>CFBundleShortVersionString</key>.
sed -i '' "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>[^<]*</string>|<string>${VERSION}</string>|;}" "$INFO_PLIST"
report "$INFO_PLIST" "<string>${VERSION}</string>"

# Patch the <string> on the line AFTER <key>CFBundleVersion</key>.
sed -i '' "/<key>CFBundleVersion<\/key>/{n;s|<string>[^<]*</string>|<string>${VERSION}</string>|;}" "$INFO_PLIST"

echo "Done."
