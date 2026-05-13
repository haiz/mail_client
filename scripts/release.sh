#!/usr/bin/env bash
# Cut a new LiteMail release: bump version, build .app bundle, ad-hoc sign,
# zip, commit, tag, push, and create a GitHub release.
#
# Usage: ./scripts/release.sh <new-version> [--notes "release notes"]
#   e.g. ./scripts/release.sh 0.2.0
#   e.g. ./scripts/release.sh 0.2.0 --notes "- Fixed X\n- Added Y"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ── Args ──────────────────────────────────────────────────────────────────────
NEW_VERSION="${1:-}"
RELEASE_NOTES_ARG=""

shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes)
            RELEASE_NOTES_ARG="${2:-}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$NEW_VERSION" ]]; then
    echo "Usage: $0 <new-version> [--notes \"release notes\"]"
    echo "  e.g. $0 0.2.0"
    echo "  e.g. $0 0.2.0 --notes \"- Fixed X\\n- Added Y\""
    exit 1
fi

if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: '$NEW_VERSION' is not valid semver (X.Y.Z)" >&2
    exit 1
fi

OLD_VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ "$NEW_VERSION" == "$OLD_VERSION" ]]; then
    echo "error: new version ($NEW_VERSION) is the same as current ($OLD_VERSION)" >&2
    exit 1
fi

# ── Preflight checks ──────────────────────────────────────────────────────────
for cmd in swift gh shasum ditto codesign plutil; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "error: '$cmd' not found in PATH" >&2
        exit 1
    fi
done

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty — commit or stash first" >&2
    exit 1
fi

echo "==> Releasing $OLD_VERSION → $NEW_VERSION"

# ── 1. Bump version ───────────────────────────────────────────────────────────
echo ""
echo "==> Step 1: Bump version"
printf '%s\n' "$NEW_VERSION" > VERSION
./scripts/sync-version.sh

# ── 2. Build icon if needed ───────────────────────────────────────────────────
ICNS_PATH="$REPO_ROOT/Sources/LiteMail/Resources/AppIcon.icns"
if [[ ! -f "$ICNS_PATH" ]]; then
    echo ""
    echo "==> Step 2: Build icon (AppIcon.icns missing)"
    if ! command -v rsvg-convert &>/dev/null; then
        echo "error: 'rsvg-convert' not found — install with: brew install librsvg" >&2
        exit 1
    fi
    ./scripts/build-icon.sh
else
    echo ""
    echo "==> Step 2: Icon already present, skipping build"
fi

# ── 3. Run tests ──────────────────────────────────────────────────────────────
echo ""
echo "==> Step 3: Run tests"
# LiteMailProtocolTests requires a running Docker GreenMail container — skipped here.
# Run them separately with: docker compose -f docker-compose.test.yml up -d && swift test --filter LiteMailProtocolTests
swift test --filter LiteMailTests 2>&1 | tail -5
swift test --filter LiteMailIntegrationTests 2>&1 | tail -5
swift test --filter LiteMailGUITests 2>&1 | tail -5

# ── 4. Build release binary ───────────────────────────────────────────────────
echo ""
echo "==> Step 4: Build release binary"
# Produces:
#   .build/release/LiteMail              — the executable
#   .build/release/LiteMail_LiteMail.bundle — SwiftPM resource bundle (if any resources exist)
swift build -c release 2>&1 | tail -3

RELEASE_BIN="$REPO_ROOT/.build/release/LiteMail"
if [[ ! -f "$RELEASE_BIN" ]]; then
    echo "error: $RELEASE_BIN not found after build" >&2
    exit 1
fi

# ── 5. Assemble .app bundle ───────────────────────────────────────────────────
echo ""
echo "==> Step 5: Assemble LiteMail.app"
STAGING="$REPO_ROOT/.build/release-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"

APP="$STAGING/LiteMail.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Info.plist (already synced to new version)
cp "$REPO_ROOT/Sources/LiteMail/Resources/Info.plist" "$APP/Contents/Info.plist"

# Executable
cp "$RELEASE_BIN" "$APP/Contents/MacOS/LiteMail"
chmod +x "$APP/Contents/MacOS/LiteMail"

# SwiftPM resource bundle — must sit next to the executable for Bundle.module to resolve it
RESOURCE_BUNDLE="$REPO_ROOT/.build/release/LiteMail_LiteMail.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/MacOS/LiteMail_LiteMail.bundle"
fi

# App icon
cp "$ICNS_PATH" "$APP/Contents/Resources/AppIcon.icns"

echo "  Bundle structure:"
find "$APP" -maxdepth 3 | sed 's|.*/||' | sort | while read -r f; do echo "    $f"; done

# ── 6. Ad-hoc code sign ───────────────────────────────────────────────────────
echo ""
echo "==> Step 6: Ad-hoc sign"
# Note: users who download this app must right-click → Open to bypass Gatekeeper,
# or run: xattr -dr com.apple.quarantine LiteMail.app
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "  Signature: OK (ad-hoc)"

# ── 7. Smoke-test Info.plist ──────────────────────────────────────────────────
plutil -lint "$APP/Contents/Info.plist" > /dev/null
echo "  Info.plist: valid"

# ── 8. Zip ────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 7: Create LiteMail.app.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/LiteMail.app.zip"
echo "  LiteMail.app.zip — $(du -h "$STAGING/LiteMail.app.zip" | cut -f1 | xargs)"

# ── 9. Checksum ───────────────────────────────────────────────────────────────
echo ""
echo "==> Step 8: Compute sha256"
APP_SHA="$(shasum -a 256 "$STAGING/LiteMail.app.zip" | awk '{print $1}')"
echo "  sha256: $APP_SHA"

# ── 10. Commit, tag, push ─────────────────────────────────────────────────────
echo ""
echo "==> Step 9: Commit, tag, push"
git add VERSION Sources/LiteMail/Resources/Info.plist
git commit -m "chore: release v${NEW_VERSION}"
git tag "v${NEW_VERSION}"
git push
git push --tags

# ── 11. Create GitHub release ─────────────────────────────────────────────────
echo ""
echo "==> Step 10: Create GitHub release"
if [[ -n "$RELEASE_NOTES_ARG" ]]; then
    NOTES_FLAGS=(--notes "$RELEASE_NOTES_ARG")
else
    NOTES_FLAGS=(--generate-notes)
fi

RELEASE_URL=$(gh release create "v${NEW_VERSION}" \
    "$STAGING/LiteMail.app.zip" \
    --title "v${NEW_VERSION}" \
    "${NOTES_FLAGS[@]}")

# ── 12. Verify uploaded artifact checksum ─────────────────────────────────────
echo ""
echo "==> Step 11: Verify uploaded artifact"
VERIFY_DIR="$(mktemp -d)"
gh release download "v${NEW_VERSION}" \
    -p 'LiteMail.app.zip' \
    -D "$VERIFY_DIR"

DL_SHA="$(shasum -a 256 "$VERIFY_DIR/LiteMail.app.zip" | awk '{print $1}')"
rm -rf "$VERIFY_DIR"

if [[ "$DL_SHA" != "$APP_SHA" ]]; then
    echo "  warning: checksum mismatch (local: $APP_SHA / uploaded: $DL_SHA)"
    echo "  GitHub may have recompressed the zip. Users should verify against the uploaded sha256."
else
    echo "  Checksum verified: $APP_SHA"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -rf "$STAGING"

echo ""
echo "==> Done! $RELEASE_URL"
