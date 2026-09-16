#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
PACKAGE="$ROOT/Scripts/package-apps.sh"
KIT="$ROOT/Artifacts/Sensorium"
ARCHIVE="$ROOT/Artifacts/Sensorium.zip"

# Never signs with the real, keychain-backed signing identity: every
# packager invocation below names an identity guaranteed absent from the
# keychain, so codesign never prompts for that key's use.
FAKE_IDENTITY="Sensorium Test Nonexistent Identity $$"

[ -x "$PACKAGE" ]
# Simulates a kit built by an older, pre-rename version of this script still
# sitting in Artifacts/. If the packaging script wrote the renamed bundle
# alongside this one instead of removing it first, both would carry
# com.sensorium.host and satisfy the same designated requirement -- TCC
# would authorize either, and which one Launch Services actually opens
# would be silently ambiguous.
mkdir -p "$KIT/sensoriumd.app/Contents/MacOS"
: > "$KIT/sensoriumd.app/Contents/MacOS/sensoriumd"
SENSORIUM_SIGN_IDENTITY="$FAKE_IDENTITY" SENSORIUM_ALLOW_ADHOC=1 "$PACKAGE"

[ ! -e "$KIT/sensoriumd.app" ]
[ -x "$KIT/Sensorium.app/Contents/MacOS/Sensorium" ]
[ -x "$KIT/Sensorium Host.app/Contents/MacOS/SensoriumHost" ]
# The apps ship flat, with no `.command` launcher, which is test scaffolding,
# not a deliverable a real user sees.
[ -z "$(find "$KIT" -maxdepth 1 -name '*.command')" ]
[ -f "$KIT/Sensorium.app/Contents/Resources/Sensorium.icns" ]
[ -f "$KIT/Sensorium Host.app/Contents/Resources/SensoriumHost.icns" ]
plutil -lint "$KIT/Sensorium.app/Contents/Info.plist"
plutil -lint "$KIT/Sensorium Host.app/Contents/Info.plist"
[ "$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - "$KIT/Sensorium.app/Contents/Info.plist")" = "sensorium" ]
[ "$(plutil -extract CFBundleIconFile raw -o - "$KIT/Sensorium.app/Contents/Info.plist")" = "Sensorium" ]
[ "$(plutil -extract CFBundleIconFile raw -o - "$KIT/Sensorium Host.app/Contents/Info.plist")" = "SensoriumHost" ]
# Finder shows the bundle filename, not CFBundleName -- so the owner sees
# "Sensorium Host" everywhere only if the filename carries the space too;
# CFBundleDisplayName is what some surfaces prefer over CFBundleName.
[ "$(plutil -extract CFBundleName raw -o - "$KIT/Sensorium Host.app/Contents/Info.plist")" = "Sensorium Host" ]
[ "$(plutil -extract CFBundleDisplayName raw -o - "$KIT/Sensorium Host.app/Contents/Info.plist")" = "Sensorium Host" ]
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$KIT/Sensorium.app/Contents/Info.plist")" = "$VERSION" ]
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$KIT/Sensorium Host.app/Contents/Info.plist")" = "$VERSION" ]
# The About panel falls back to this when the running binary is bundled.
[ "$(plutil -extract NSHumanReadableCopyright raw -o - "$KIT/Sensorium.app/Contents/Info.plist")" = "© 2026 blutarche · GPL-3.0" ]
[ "$(plutil -extract NSHumanReadableCopyright raw -o - "$KIT/Sensorium Host.app/Contents/Info.plist")" = "© 2026 blutarche · GPL-3.0" ]
# Accessibility is the permission the product depends on most, and the host
# plist declared no explanation for it while declaring one for the other two.
for key in NSScreenCaptureUsageDescription NSAppleEventsUsageDescription NSAccessibilityUsageDescription; do
  value="$(plutil -extract "$key" raw -o - "$KIT/Sensorium Host.app/Contents/Info.plist")"
  case "$value" in
    ?*) ;;
    *) echo "Host app declares no $key" >&2; exit 1 ;;
  esac
done
# The icon is written before signing; if that order ever flips, these fail.
codesign --verify --strict "$KIT/Sensorium.app"
codesign --verify --strict "$KIT/Sensorium Host.app"
if plutil -extract LSBackgroundOnly raw -o - "$KIT/Sensorium Host.app/Contents/Info.plist" >/dev/null 2>&1; then
  echo "Host app must be foreground-capable while its session workspace owns keyboard focus" >&2
  exit 1
fi

# The viewer goes to whatever Mac its owner works from, so both architectures
# have to be in the one binary; the host only ever runs on Apple silicon.
VIEWER_ARCHS="$(lipo -archs "$KIT/Sensorium.app/Contents/MacOS/Sensorium")"
for arch in x86_64 arm64; do
  case " $VIEWER_ARCHS " in
    *" $arch "*) ;;
    *) echo "Viewer binary is missing $arch; it must run on any Mac" >&2; exit 1 ;;
  esac
done
case "$(file "$KIT/Sensorium Host.app/Contents/MacOS/SensoriumHost")" in
  *arm64*) ;;
  *) echo "Host binary is not arm64" >&2; exit 1 ;;
esac

# The apps ship flat by role. A folder named after one machine is a folder
# the next machine's owner has to be told to ignore.
for stale in Intel-MacBook Mac-mini; do
  [ ! -e "$KIT/$stale" ] || { echo "Package still names a machine: $stale" >&2; exit 1; }
done

unzip -t "$ARCHIVE" >/dev/null

# Ad-hoc signing must be an explicit, asked-for exception, never the silent
# default: it gives each rebuild a fresh, build-specific designated
# requirement, which drops the owner's Screen Recording/Accessibility
# grants without warning. Overriding SENSORIUM_SIGN_IDENTITY to a name no
# signing certificate carries exercises this.
if SENSORIUM_SIGN_IDENTITY="$FAKE_IDENTITY" "$PACKAGE" >/dev/null 2>&1; then
  echo "package-apps.sh must fail without a real signing identity when SENSORIUM_ALLOW_ADHOC is unset" >&2
  exit 1
fi
SENSORIUM_SIGN_IDENTITY="$FAKE_IDENTITY" SENSORIUM_ALLOW_ADHOC=1 "$PACKAGE" >/dev/null
if ! codesign -d -r- "$KIT/Sensorium Host.app" 2>&1 | grep -qF '# designated => cdhash'; then
  echo "SENSORIUM_ALLOW_ADHOC=1 did not produce an ad-hoc, cdhash-based signature" >&2
  exit 1
fi

printf 'PASS: reproducible packaged apps, named by role\n'
