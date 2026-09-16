#!/bin/sh
# Builds the two apps into Artifacts/Sensorium and zips them. Signs with
# SENSORIUM_SIGN_IDENTITY (default Sensorium) or ad-hoc with
# SENSORIUM_ALLOW_ADHOC=1. Never changes macOS permissions or firewall state.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
KIT="$ROOT/Artifacts/Sensorium"
ARCHIVE="$ROOT/Artifacts/Sensorium.zip"
CLIENT_BIN_X86_64="$ROOT/.build/x86_64-apple-macosx/release/Sensorium"
CLIENT_BIN_ARM64="$ROOT/.build/arm64-apple-macosx/release/Sensorium"
CLIENT_BIN_UNIVERSAL="$ROOT/.build/Sensorium-universal"
HOST_BIN="$ROOT/.build/arm64-apple-macosx/release/sensoriumd"
ICONS="$ROOT/.build/icons"

cd "$ROOT"
# The viewer has to run on whatever machine its owner works from, x86_64 or
# arm64, so it is a universal binary; the host (sensoriumd) runs only
# on the arm64 machine, so it stays single-arch (native arm64, no
# --triple needed).
swift build -c release --product Sensorium --triple x86_64-apple-macosx13.0
swift build -c release --product Sensorium --triple arm64-apple-macosx13.0
swift build -c release --product sensoriumd

test -x "$CLIENT_BIN_X86_64"
test -x "$CLIENT_BIN_ARM64"
test -x "$HOST_BIN"
lipo -create -output "$CLIENT_BIN_UNIVERSAL" "$CLIENT_BIN_X86_64" "$CLIENT_BIN_ARM64"
CLIENT_BIN="$CLIENT_BIN_UNIVERSAL"
rm -rf "$KIT"
mkdir -p \
  "$KIT/Sensorium.app/Contents/MacOS" \
  "$KIT/Sensorium.app/Contents/Resources" \
  "$KIT/Sensorium Host.app/Contents/MacOS" \
  "$KIT/Sensorium Host.app/Contents/Resources"

install -m 755 "$CLIENT_BIN" "$KIT/Sensorium.app/Contents/MacOS/Sensorium"
install -m 755 "$HOST_BIN" "$KIT/Sensorium Host.app/Contents/MacOS/SensoriumHost"

cat > "$KIT/Sensorium.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Sensorium</string>
    <key>CFBundleIdentifier</key><string>com.sensorium.viewer</string>
    <key>CFBundleName</key><string>Sensorium</string>
    <key>CFBundleIconFile</key><string>Sensorium</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>__SENSORIUM_VERSION__</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>&#169; 2026 blutarche &#183; GPL-3.0</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.sensorium.enter</string>
            <key>CFBundleURLSchemes</key><array><string>sensorium</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

cat > "$KIT/Sensorium Host.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SensoriumHost</string>
    <key>CFBundleIdentifier</key><string>com.sensorium.host</string>
    <key>CFBundleName</key><string>Sensorium Host</string>
    <key>CFBundleDisplayName</key><string>Sensorium Host</string>
    <key>CFBundleIconFile</key><string>SensoriumHost</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>__SENSORIUM_VERSION__</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Sensorium captures the virtual canvas it creates for a session, or a screen of this machine when a person here has shared it.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Sensorium delivers the keyboard and pointer input from your other machine to the session canvas.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>Sensorium types and clicks on the session canvas on behalf of the machine you are working from. It uses this for nothing else: without it the session is view-only.</string>
    <key>NSHumanReadableCopyright</key><string>&#169; 2026 blutarche &#183; GPL-3.0</string>
</dict>
</plist>
PLIST

# The heredocs above stay quoted so their XML entities (&#169;, &#183;) are
# written literally; substitute the version afterward instead of unquoting.
sed -i '' "s/__SENSORIUM_VERSION__/$VERSION/" \
  "$KIT/Sensorium.app/Contents/Info.plist" \
  "$KIT/Sensorium Host.app/Contents/Info.plist"

# Without an icon both apps show the blank generic tile, including in the
# System Settings rows the operator has to find and approve. The generator is
# deterministic, so regenerating it keeps this kit byte-reproducible.
swift "$ROOT/Scripts/make-app-icons.swift" "$ICONS" >/dev/null
install -m 644 "$ICONS/Sensorium.icns" "$KIT/Sensorium.app/Contents/Resources/Sensorium.icns"
install -m 644 "$ICONS/SensoriumHost.icns" "$KIT/Sensorium Host.app/Contents/Resources/SensoriumHost.icns"

# Both .app bundles are now fully assembled (executable + Info.plist + icon
# copied in). Sign last: any later write to a bundle invalidates its signature.
SIGN_IDENTITY="${SENSORIUM_SIGN_IDENTITY:-Sensorium}"
if security find-identity -v -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
  SIGN_AS="$SIGN_IDENTITY"
elif [ "${SENSORIUM_ALLOW_ADHOC:-0}" = "1" ]; then
  printf 'warning: code-signing identity "%s" not found; signing ad-hoc, so Screen Recording/Accessibility grants will not survive rebuilds\n' "$SIGN_IDENTITY" >&2
  SIGN_AS="-"
else
  cat >&2 <<EOF
error: code-signing identity "$SIGN_IDENTITY" is not in the keychain.
Ad-hoc signing invalidates the Screen Recording and Accessibility grants
already approved for this app.
Import or unlock that identity, set SENSORIUM_SIGN_IDENTITY, or rerun with
SENSORIUM_ALLOW_ADHOC=1.
EOF
  exit 1
fi

# One codesign process for both bundles: a real (non-ad-hoc) identity backed
# by a keychain-protected key can prompt for that key's use, and each
# separate codesign invocation is a separate prompt.
codesign --force --sign "$SIGN_AS" "$KIT/Sensorium Host.app" "$KIT/Sensorium.app"

verify_app_bundle() {
  APP="$1"
  codesign --verify --strict "$APP"
  # codesign's own failure here is generic; this names the field a stored TCC
  # grant is keyed to.
  SIGNED_IDENTIFIER="$(codesign -dv "$APP" 2>&1 | sed -n 's/^Identifier=//p')"
  PLIST_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")"
  if [ "$SIGNED_IDENTIFIER" != "$PLIST_IDENTIFIER" ]; then
    printf 'error: %s signed with Identifier=%s but Info.plist declares CFBundleIdentifier=%s\n' \
      "$APP" "$SIGNED_IDENTIFIER" "$PLIST_IDENTIFIER" >&2
    exit 1
  fi
  printf 'Designated requirement for %s:\n' "$APP"
  codesign -d -r- "$APP" 2>&1
}

verify_app_bundle "$KIT/Sensorium Host.app"
verify_app_bundle "$KIT/Sensorium.app"

rm -f "$ARCHIVE"
ditto -c -k --keepParent "$KIT" "$ARCHIVE"
printf 'Built %s\n' "$ARCHIVE"
