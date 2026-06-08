#!/usr/bin/env bash
# Build botworld as a dev-signed iOS app and push it onto a connected iPhone.
#
# Usage:   make ios                 (auto-detects signing identity + device)
# Or:      TEAM_ID=ABC123XYZ0 DEVICE=<udid> make ios
#
# One-time prerequisites (all free, no paid developer account needed):
#   1. Xcode installed, opened once, signed into your Apple ID
#      (Xcode > Settings > Accounts > add Apple ID).
#   2. iPhone plugged in via USB, "Trust This Computer" accepted.
#   3. Developer Mode enabled on the phone
#      (Settings > Privacy & Security > Developer Mode, then reboot).
#
# Free-account builds expire after 7 days; just run `make ios` again.
set -euo pipefail

LOVE_FILE="${1:?usage: ios.sh path/to/game.love}"
[ -f "$LOVE_FILE" ] || { echo "error: $LOVE_FILE not found (run via 'make ios')" >&2; exit 1; }
LOVE_FILE="$(cd "$(dirname "$LOVE_FILE")" && pwd)/$(basename "$LOVE_FILE")"
LOVE_VERSION="${LOVE_VERSION:-11.5}"
BUNDLE_ID="${BUNDLE_ID:-com.theroymind.botworld}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/ios"
SRC="$BUILD/love-$LOVE_VERSION-ios-source"
DERIVED="$BUILD/derived"
mkdir -p "$BUILD"

[ "$(uname)" = "Darwin" ] || { echo "error: make ios needs macOS + Xcode" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "error: Xcode not installed (xcodebuild missing)" >&2; exit 1; }

# --- 1. Fetch the LÖVE iOS source (cached after first run) -------------------
if [ ! -d "$SRC" ]; then
  echo "==> Downloading LÖVE $LOVE_VERSION iOS source..."
  curl -fL --retry 3 -o "$BUILD/ios-source.zip" \
    "https://github.com/love2d/love/releases/download/$LOVE_VERSION/love-$LOVE_VERSION-ios-source.zip"
  unzip -q "$BUILD/ios-source.zip" -d "$BUILD"
  rm "$BUILD/ios-source.zip"
  [ -d "$SRC" ] || { echo "error: unexpected zip layout; look in $BUILD" >&2; exit 1; }
fi

# --- 2. Resolve signing identity + team --------------------------------------
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')"
if [ -z "$IDENTITY" ]; then
  echo "error: no 'Apple Development' signing certificate found." >&2
  echo "Open Xcode > Settings > Accounts, add your Apple ID, then under" >&2
  echo "'Manage Certificates...' create an Apple Development certificate." >&2
  exit 1
fi
if [ -z "${TEAM_ID:-}" ]; then
  # The OU field of an Apple Development cert is the team ID.
  TEAM_ID="$(security find-certificate -c "Apple Development" -p \
    | openssl x509 -noout -subject \
    | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')"
fi
[ -n "$TEAM_ID" ] || { echo "error: could not detect team ID; pass TEAM_ID=... (see Xcode > Settings > Accounts)" >&2; exit 1; }
echo "==> Signing as: $IDENTITY (team $TEAM_ID)"

# --- 3. Build the LÖVE app shell ----------------------------------------------
echo "==> Building love-ios (first build is slow; later ones are incremental)..."
xcodebuild build \
  -project "$SRC/platform/xcode/love.xcodeproj" \
  -scheme love-ios \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  -quiet

APP="$(ls -d "$DERIVED/Build/Products/Debug-iphoneos/"*.app 2>/dev/null | head -1)"
[ -n "$APP" ] || { echo "error: built .app not found under $DERIVED" >&2; exit 1; }

# --- 4. Fuse the game in and re-sign ------------------------------------------
echo "==> Embedding $(basename "$LOVE_FILE") into $(basename "$APP")"
cp "$LOVE_FILE" "$APP/"
codesign --force --sign "$IDENTITY" \
  --preserve-metadata=identifier,entitlements,flags "$APP"

# --- 5. Install (and try to launch) on the device ------------------------------
if [ -z "${DEVICE:-}" ]; then
  DEVICE="$(xcrun devicectl list devices --json-output "$BUILD/devices.json" >/dev/null 2>&1 \
    && python3 -c "
import json
devices = json.load(open('$BUILD/devices.json'))['result']['devices']
paired = [d for d in devices
          if d.get('connectionProperties', {}).get('pairingState') == 'paired']
pick = (paired or devices)
print(pick[0]['identifier'] if pick else '')")"
fi
if [ -z "$DEVICE" ]; then
  echo "warning: no paired iPhone found. App built at:" >&2
  echo "  $APP" >&2
  echo "Plug the phone in (trust the computer) and re-run, or pass DEVICE=<udid>." >&2
  exit 1
fi

echo "==> Installing on device $DEVICE..."
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "==> Launching..."
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" \
  || echo "(launch failed -- phone probably locked; tap the icon yourself)"
echo "==> Done."
