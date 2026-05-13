#!/bin/bash
set -euo pipefail

# LiteMail Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/haiz/mail_client/main/install.sh | bash

APP_NAME="LiteMail"
APP_BUNDLE="LiteMail.app"
INSTALL_DIR="/Applications"
REPO="haiz/mail_client"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}==>${NC} $1"; }
ok()    { echo -e "${GREEN}==>${NC} $1"; }
warn()  { echo -e "${YELLOW}==>${NC} $1"; }
error() { echo -e "${RED}==>${NC} $1"; exit 1; }

# --- Pre-flight checks ---
[[ "$(uname)" == "Darwin" ]] || error "This app requires macOS."

MACOS_VERSION=$(sw_vers -productVersion)
MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)
[[ "$MAJOR" -ge 14 ]] || error "macOS 14 (Sonoma) or later is required. You have $MACOS_VERSION."

info "Installing ${APP_NAME}..."

# --- Get latest release URL ---
info "Fetching latest release..."
RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest") \
  || error "Failed to fetch release info. Check your internet connection."

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)
VERSION=$(echo "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)

[[ -n "$DOWNLOAD_URL" ]] || error "No .zip asset found in the latest release."

info "Found ${APP_NAME} ${VERSION}"

# --- Download ---
TMPDIR_PATH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_PATH"' EXIT

ZIP_PATH="${TMPDIR_PATH}/${APP_BUNDLE}.zip"
info "Downloading..."
curl -fSL --progress-bar -o "$ZIP_PATH" "$DOWNLOAD_URL" \
  || error "Download failed."

# --- Install ---
info "Installing to ${INSTALL_DIR}..."

# Remove previous installation if exists
if [[ -d "${INSTALL_DIR}/${APP_BUNDLE}" ]]; then
  warn "Removing previous installation..."
  rm -rf "${INSTALL_DIR}/${APP_BUNDLE}"
fi

# Unzip
ditto -xk "$ZIP_PATH" "$INSTALL_DIR" \
  || error "Failed to extract app."

# Remove quarantine attribute (app is ad-hoc signed, not notarized)
xattr -cr "${INSTALL_DIR}/${APP_BUNDLE}" 2>/dev/null || true

# --- Done ---
echo ""
ok "${APP_NAME} ${VERSION} installed successfully!"
echo ""
echo "  Open from Spotlight:  open -a '${APP_NAME}'"
echo "  Or find it in:        ${INSTALL_DIR}/${APP_BUNDLE}"
echo ""
warn "Note: On first launch, if macOS blocks the app:"
echo "  System Settings > Privacy & Security > scroll down > Open Anyway"
echo ""
