#!/usr/bin/env bash
# Build, package, and upload a LiteMail release to GitHub.
# Usage: ./release.sh <tag>  (e.g. ./release.sh v0.3.1)
set -euo pipefail

TAG="${1:-}"
[[ -n "$TAG" ]] || { echo "Usage: $0 <tag> (e.g. v0.3.1)"; exit 1; }

APP_NAME="LiteMail"
APP_BUNDLE="${APP_NAME}.app"
BUILD_DIR=".build/release"
STAGING=$(mktemp -d)
APP_PATH="${STAGING}/${APP_BUNDLE}"
ZIP_PATH="${STAGING}/${APP_NAME}.zip"

cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

echo "==> Building ${APP_NAME} ${TAG} (release)..."
swift build -c release

echo "==> Assembling app bundle..."
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}"                    "${APP_PATH}/Contents/MacOS/"
cp "Sources/LiteMail/Resources/Info.plist"       "${APP_PATH}/Contents/"
cp "Sources/LiteMail/Resources/AppIcon.icns"     "${APP_PATH}/Contents/Resources/"

for bundle in "${BUILD_DIR}"/*.bundle; do
    cp -r "$bundle" "${APP_PATH}/Contents/Resources/"
done

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "${APP_PATH}"

echo "==> Creating zip..."
ditto -ck --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "==> Uploading to GitHub release ${TAG}..."
gh release upload "${TAG}" "${ZIP_PATH}" --clobber

echo "==> Done. ${APP_NAME}.zip uploaded to release ${TAG}."
