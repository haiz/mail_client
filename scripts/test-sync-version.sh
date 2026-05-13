#!/usr/bin/env bash
# Test harness for scripts/sync-version.sh.
# Builds a temp fixture from the real Info.plist, runs the script, asserts expectations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$SCRIPT_DIR/sync-version.sh"
REAL_PLIST="$REPO_ROOT/Sources/LiteMail/Resources/Info.plist"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
ko() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# Build a temp dir with only the files sync-version.sh needs.
make_fixture() {
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/Sources/LiteMail/Resources" "$tmp/scripts"
    cp "$REAL_PLIST" "$tmp/Sources/LiteMail/Resources/Info.plist"
    cp "$SYNC" "$tmp/scripts/sync-version.sh"
    chmod +x "$tmp/scripts/sync-version.sh"
    echo "$tmp"
}

# --- Test 1: happy path bumps both version keys. ---
echo "Test 1: happy path"
T1="$(make_fixture)"
echo "9.9.9" > "$T1/VERSION"
"$T1/scripts/sync-version.sh" >/dev/null
grep -A1 "CFBundleShortVersionString" "$T1/Sources/LiteMail/Resources/Info.plist" \
    | grep -q "<string>9.9.9</string>" && ok "CFBundleShortVersionString bumped" || ko "CFBundleShortVersionString bumped"
grep -A1 "CFBundleVersion" "$T1/Sources/LiteMail/Resources/Info.plist" \
    | grep -q "<string>9.9.9</string>" && ok "CFBundleVersion bumped" || ko "CFBundleVersion bumped"
rm -rf "$T1"

# --- Test 2: idempotency — running twice with same VERSION produces zero diff. ---
echo "Test 2: idempotency"
T2="$(make_fixture)"
echo "2.3.4" > "$T2/VERSION"
"$T2/scripts/sync-version.sh" >/dev/null
SNAP="$(mktemp -d)"
cp "$T2/Sources/LiteMail/Resources/Info.plist" "$SNAP/Info.plist"
"$T2/scripts/sync-version.sh" >/dev/null
diff -q "$SNAP/Info.plist" "$T2/Sources/LiteMail/Resources/Info.plist" >/dev/null \
    && ok "Info.plist idempotent" || ko "Info.plist idempotent"
rm -rf "$T2" "$SNAP"

# --- Test 3: malformed VERSION is rejected. ---
echo "Test 3: malformed VERSION rejected"
T3="$(make_fixture)"
echo "v1.2.3" > "$T3/VERSION"
if "$T3/scripts/sync-version.sh" >/dev/null 2>&1; then
    ko "malformed 'v1.2.3' should be rejected"
else
    ok "malformed 'v1.2.3' rejected"
fi
rm -rf "$T3"

# --- Test 4: empty VERSION is rejected. ---
echo "Test 4: empty VERSION rejected"
T4="$(make_fixture)"
: > "$T4/VERSION"
if "$T4/scripts/sync-version.sh" >/dev/null 2>&1; then
    ko "empty VERSION should be rejected"
else
    ok "empty VERSION rejected"
fi
rm -rf "$T4"

# --- Test 5: missing VERSION file is rejected. ---
echo "Test 5: missing VERSION rejected"
T5="$(make_fixture)"
# deliberately omit VERSION
if "$T5/scripts/sync-version.sh" >/dev/null 2>&1; then
    ko "missing VERSION should be rejected"
else
    ok "missing VERSION rejected"
fi
rm -rf "$T5"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
