#!/bin/sh
# Runs the full unit suite, then builds a signed release of both macOS apps and
# checks each zip and disk image the way a downloader sees it. Produces, in
# Artifacts/release:
#   Sensorium-<version>.zip, Sensorium-Host-<version>.zip,
#   Sensorium-<version>.dmg, Sensorium-Host-<version>.dmg, SHA256SUMS,
#   sensorium-update.json and sensorium-update.json.sig
# The zips are for self-update. The disk images are downloads for people and
# are not signed themselves; the app inside each is the signed app. Each opens
# to a window drawn by Scripts/make-dmg-background.swift and laid out by
# Scripts/make-dmg-layout.swift.
# The manifest is signed with the update key (SENSORIUM_UPDATE_KEY, else
# $HOME/.sensorium-release/update-key), whose public half must be the one
# compiled into the apps. Uploads to the GitHub release v<version> only with
# --upload. Never signs ad hoc, and never changes macOS permissions or
# firewall state.
set -eu

# The designated requirement of every installed app names this certificate
# leaf. A release signed with any other certificate fails each installed
# app's update check, so the script refuses one. Someone building their own
# fork sets SENSORIUM_RELEASE_CERT_LEAF to their certificate's leaf instead.
RELEASE_CERT_LEAF="${SENSORIUM_RELEASE_CERT_LEAF:-H\"87558db5f8fd5d678dfa2a503aaf4b39d49ff515\"}"
SELF_TEST_SECONDS="${SENSORIUM_SELF_TEST_SECONDS:-10}"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
KIT="$ROOT/Artifacts/Sensorium"
OUT="$ROOT/Artifacts/release"
TAG="v$VERSION"
SIGN="$ROOT/Scripts/sign-update.swift"
KEY="${SENSORIUM_UPDATE_KEY:-$HOME/.sensorium-release/update-key}"

UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
    *) printf 'usage: %s [--upload]\n' "$0" >&2; exit 2 ;;
  esac
done

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Check the signing key before the long build.
[ -f "$KEY" ] || die "the update key file $KEY does not exist. Set SENSORIUM_UPDATE_KEY to your key file, or create one with: swift Scripts/sign-update.swift generate <key file>"
KEY_PUBLIC="$(swift "$SIGN" public-key "$KEY")" || die "the update key file $KEY cannot be used"
COMPILED_FILE="$ROOT/Sources/SensoriumUpdate/UpdatePublicKey.swift"
[ -f "$COMPILED_FILE" ] || die "$COMPILED_FILE is missing, so the key compiled into the apps is unknown"
COMPILED_KEYS="$(grep -Eo '"[A-Za-z0-9+/]{43}="' "$COMPILED_FILE" | tr -d '"' || true)"
[ -n "$COMPILED_KEYS" ] && [ "$(printf '%s\n' "$COMPILED_KEYS" | wc -l | tr -d ' ')" = 1 ] ||
  die "$COMPILED_FILE must hold exactly one base64 string of 32 bytes"
[ "$(printf '%s' "$COMPILED_KEYS" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ] ||
  die "the string in $COMPILED_FILE is not 32 bytes"
[ "$KEY_PUBLIC" = "$COMPILED_KEYS" ] ||
  die "the public key of $KEY does not match the public key compiled into the apps; signing with it would make every installed app reject the update"

if [ "$UPLOAD" = 1 ]; then
  command -v gh >/dev/null 2>&1 || die "gh is not installed, so the release cannot be uploaded"
  gh release view "$TAG" >/dev/null 2>&1 ||
    die "GitHub release $TAG does not exist. Create it first, then rerun with --upload."
fi

# Continuous integration skips the runners that open windows, so the full suite
# is run here, where there is a GUI session, before anything is signed or built.
"$ROOT/Scripts/run-unit-tests.sh" || die "the unit tests failed, so no release was built. Fix them, then rerun."

# A release must carry a real certificate, so the packager may not fall back
# to ad hoc signing whatever the caller's environment says.
SENSORIUM_ALLOW_ADHOC=0 "$ROOT/Scripts/package-apps.sh"

VIEWER_ZIP="Sensorium-$VERSION.zip"
HOST_ZIP="Sensorium-Host-$VERSION.zip"
VIEWER_DMG="Sensorium-$VERSION.dmg"
HOST_DMG="Sensorium-Host-$VERSION.dmg"

rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --keepParent "$KIT/Sensorium.app" "$OUT/$VIEWER_ZIP"
ditto -c -k --keepParent "$KIT/Sensorium Host.app" "$OUT/$HOST_ZIP"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sensorium-release.XXXXXX")"
ATTACHED=""
# A volume can stay busy for a moment after its last reader closes, so retry
# before forcing. Returns non-zero only when every attempt failed.
detach_volume() {
  for attempt in 1 2 3; do
    hdiutil detach "$1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  hdiutil detach -force "$1" >/dev/null 2>&1
}

cleanup() {
  if [ -n "$ATTACHED" ]; then
    detach_volume "$ATTACHED" || true
  fi
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

leaf_of() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/.*certificate leaf = \(H"[0-9a-fA-F]*"\).*/\1/p' | head -n 1
}

plist_value() {
  plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

# cdhash_of <app> <architecture>: codesign reports one slice at a time.
cdhash_of() {
  codesign -dvvv --arch "$2" "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1
}

# same_slices <first app> <second app> <label> <first file> <second file> <architectures>
# Dies unless every listed architecture has the same non-empty CDHash in both apps.
same_slices() {
  for arch in $6; do
    FIRST_HASH="$(cdhash_of "$1" "$arch")"
    SECOND_HASH="$(cdhash_of "$2" "$arch")"
    [ -n "$FIRST_HASH" ] && [ "$FIRST_HASH" = "$SECOND_HASH" ] ||
      die "$3: the $arch slice of the app in $5 (CDHash '$SECOND_HASH') is not the one in $4 (CDHash '$FIRST_HASH')"
  done
}

# verify_app <app path> <file holding it> <app file name> <app label> <expected architectures>
# Checks one app the way a downloader gets it, whether from a zip or a disk image.
verify_app() {
  APP="$1"; ZIP="$2"; APP_NAME="$3"; LABEL="$4"; ARCHS="$5"
  python3 -I - "$APP" <<'PY' || die "$LABEL: $ZIP holds a symbolic link pointing outside the app, or a device or hard-linked file"
import os, stat, sys
root = os.path.realpath(sys.argv[1])
bad = False
for base, dirs, files in os.walk(sys.argv[1]):
    for name in dirs + files:
        path = os.path.join(base, name)
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            if not os.path.isabs(target):
                target = os.path.join(os.path.realpath(base), target)
            target = os.path.normpath(target)
            if target != root and not target.startswith(root + os.sep):
                bad = True
        elif stat.S_ISREG(info.st_mode):
            if info.st_nlink > 1:
                bad = True
        elif not stat.S_ISDIR(info.st_mode):
            bad = True
sys.exit(1 if bad else 0)
PY
  # A linker debug map left in an executable names every source folder and
  # object file by its absolute path on the build machine.
  python3 -I - "$APP" "/Users/" "$HOME" "$ROOT" <<'PY' || die "$LABEL: a file in $ZIP names a folder of the machine that built it"
import os, sys
needles = [s.encode() for s in sys.argv[2:] if s]
bad = False
for base, dirs, files in os.walk(sys.argv[1]):
    for name in files:
        path = os.path.join(base, name)
        if os.path.islink(path):
            continue
        with open(path, 'rb') as f:
            data = f.read()
        if any(needle in data for needle in needles):
            print(os.path.relpath(path, sys.argv[1]), file=sys.stderr)
            bad = True
sys.exit(1 if bad else 0)
PY
  codesign --verify --strict --all-architectures "$APP" 2>/dev/null ||
    die "$LABEL: the signature in $ZIP does not verify"

  for key in CFBundleIdentifier CFBundleShortVersionString; do
    GOT="$(plist_value "$APP" "$key")"
    KIT_VALUE="$(plist_value "$KIT/$APP_NAME" "$key")"
    [ "$GOT" = "$KIT_VALUE" ] || die "$LABEL: $key in $ZIP is '$GOT' but the kit has '$KIT_VALUE'"
  done
  GOT="$(plist_value "$APP" CFBundleShortVersionString)"
  [ "$GOT" = "$VERSION" ] || die "$LABEL: version in $ZIP is '$GOT' but VERSION is '$VERSION'"

  EXE="$APP/Contents/MacOS/$(plist_value "$APP" CFBundleExecutable)"
  FOUND="$(lipo -archs "$EXE" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$FOUND" = "$ARCHS" ] || die "$LABEL: architectures in $ZIP are '$FOUND' but must be '$ARCHS'"

  LEAF="$(leaf_of "$APP")"
  [ -n "$LEAF" ] ||
    die "$LABEL: the designated requirement in $ZIP names no certificate, so it was not signed with a certificate"
  [ "$(printf '%s' "$LEAF" | tr 'A-F' 'a-f')" = "$(printf '%s' "$RELEASE_CERT_LEAF" | tr 'A-F' 'a-f')" ] ||
    die "$LABEL: $ZIP is signed with certificate leaf $LEAF, but the pinned release certificate is $RELEASE_CERT_LEAF; every installed app would reject this release"
  eval "LEAF_$LABEL=\$LEAF"
}

# verify_zip <zip name> <app file name> <app label> <expected architectures>
verify_zip() {
  ZIP="$1"; APP_NAME="$2"; LABEL="$3"; ARCHS="$4"
  DIR="$SCRATCH/$ZIP"
  mkdir "$DIR"
  ditto -x -k --noqtn --noacl "$OUT/$ZIP" "$DIR"
  COUNT="$(ls -A "$DIR" | wc -l | tr -d ' ')"
  [ "$COUNT" = 1 ] || die "$LABEL: $ZIP must hold exactly one item, found $COUNT"
  APP="$DIR/$APP_NAME"
  [ -d "$APP" ] || die "$LABEL: $ZIP must hold $APP_NAME"
  [ ! -L "$APP" ] || die "$LABEL: $APP_NAME in $ZIP is a symbolic link"
  verify_app "$APP" "$ZIP" "$APP_NAME" "$LABEL" "$ARCHS"
}

# verify_dmg <dmg name> <app file name> <app label> <expected architectures> <zip name>
verify_dmg() {
  DMG="$1"; APP_NAME="$2"; LABEL="$3"; ARCHS="$4"; SRC_ZIP="$5"
  MNT="$SCRATCH/$DMG-mnt"
  mkdir "$MNT"
  hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$OUT/$DMG" >/dev/null ||
    die "$LABEL: $DMG does not attach"
  ATTACHED="$MNT"
  # Hidden entries such as .fseventsd are the filesystem's own.
  COUNT="$(ls "$MNT" | wc -l | tr -d ' ')"
  [ "$COUNT" = 2 ] || die "$LABEL: $DMG must show exactly two items, found $COUNT"
  [ -d "$MNT/$APP_NAME" ] && [ ! -L "$MNT/$APP_NAME" ] || die "$LABEL: $DMG must hold $APP_NAME as a directory"
  [ -L "$MNT/Applications" ] || die "$LABEL: $DMG must hold Applications as a symbolic link"
  [ "$(readlink "$MNT/Applications")" = "/Applications" ] ||
    die "$LABEL: Applications in $DMG must point to /Applications"
  for item in .DS_Store .background/background.tiff .VolumeIcon.icns; do
    [ -f "$MNT/$item" ] && [ ! -L "$MNT/$item" ] || die "$LABEL: $DMG must hold $item as a regular file"
  done
  has_custom_icon "$MNT" || die "$LABEL: the volume of $DMG does not use its custom icon"
  python3 -I - "$MNT/.DS_Store" "$OUT" "$SCRATCH" "$HOME" "/Users/" "/private/" ".dmg" <<'PY' || die "$LABEL: the .DS_Store in $DMG names a path of this machine"
import sys
data = open(sys.argv[1], 'rb').read()
sys.exit(1 if any(s.encode(e) in data for s in sys.argv[2:] for e in ('utf-8', 'utf-16-be', 'utf-16-le')) else 0)
PY
  verify_app "$MNT/$APP_NAME" "$DMG" "$APP_NAME" "$LABEL" "$ARCHS"
  same_slices "$SCRATCH/$SRC_ZIP/$APP_NAME" "$MNT/$APP_NAME" "$LABEL" "$SRC_ZIP" "$DMG" "$ARCHS"
  detach_volume "$MNT" || die "$LABEL: $DMG could not be detached"
  ATTACHED=""
}

# Finder shows a volume's .VolumeIcon.icns only when the custom icon flag,
# 0x0400 in the Finder flags at bytes 8 and 9 of the root folder's Finder
# info, is set.
has_custom_icon() {
  FLAGS="$(xattr -px com.apple.FinderInfo "$1" 2>/dev/null | tr -d ' \n' | cut -c17-18)"
  [ -n "$FLAGS" ] && [ "$(( 0x$FLAGS & 0x04 ))" != 0 ]
}

set_custom_icon() {
  INFO="$(xattr -px com.apple.FinderInfo "$1" 2>/dev/null | tr -d ' \n' || true)"
  [ -n "$INFO" ] || INFO="$(printf '%064d' 0)"
  FLAGS="$(printf '%02x' "$(( 0x$(printf '%s' "$INFO" | cut -c17-18) | 0x04 ))")"
  INFO="$(printf '%s' "$INFO" | cut -c1-16)$FLAGS$(printf '%s' "$INFO" | cut -c19-64)"
  xattr -wx com.apple.FinderInfo "$INFO" "$1"
}

# make_dmg <dmg name> <app file name> <volume name> <art folder>
# Builds a writable image, lays out its window, then compresses it.
make_dmg() {
  ART="$4"
  STAGE="$SCRATCH/stage-$1"
  mkdir "$STAGE" "$STAGE/.background"
  ditto "$KIT/$2" "$STAGE/$2"
  ln -s /Applications "$STAGE/Applications"
  cp "$ART/background.tiff" "$STAGE/.background/background.tiff"
  ICON="$(plist_value "$KIT/$2" CFBundleIconFile)"
  [ -n "$ICON" ] || die "$2 names no icon (CFBundleIconFile), so its disk image would have none"
  ICON="${ICON%.icns}.icns"
  [ -f "$KIT/$2/Contents/Resources/$ICON" ] || die "$2 has no icon file Contents/Resources/$ICON"
  cp "$KIT/$2/Contents/Resources/$ICON" "$STAGE/.VolumeIcon.icns"

  WRITABLE="$SCRATCH/writable-$1"
  hdiutil create -volname "$3" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WRITABLE" >/dev/null ||
    die "$1 could not be created"
  MNT="$SCRATCH/writable-$1-mnt"
  mkdir "$MNT"
  hdiutil attach -readwrite -nobrowse -noautoopen -mountpoint "$MNT" "$WRITABLE" >/dev/null ||
    die "$1 could not be attached to lay out its window"
  ATTACHED="$MNT"
  swift "$ROOT/Scripts/make-dmg-layout.swift" write "$MNT" "$3" "$2" "$ART/layout.json" ||
    die "the window of $1 could not be laid out"
  set_custom_icon "$MNT" && has_custom_icon "$MNT" || die "the volume icon of $1 could not be turned on"
  chflags hidden "$MNT/.background" "$MNT/.VolumeIcon.icns" || die "the layout files of $1 could not be hidden"
  detach_volume "$MNT" || die "$1 could not be detached after laying out its window"
  ATTACHED=""
  hdiutil convert "$WRITABLE" -format UDZO -ov -o "$OUT/$1" >/dev/null || die "$1 could not be compressed"
  rm -f "$WRITABLE"
}

verify_zip "$VIEWER_ZIP" "Sensorium.app" Viewer "arm64 x86_64"
verify_zip "$HOST_ZIP" "Sensorium Host.app" Host "arm64"

# Each disk image has its own window picture, drawn for its app's role.
for role in viewer host; do
  swift "$ROOT/Scripts/make-dmg-background.swift" "$role" "$SCRATCH/dmg-art-$role" >/dev/null ||
    die "the $role disk image background could not be drawn"
  (cd "$SCRATCH/dmg-art-$role" && tiffutil -cathidpicheck background.png background@2x.png -out background.tiff >/dev/null) ||
    die "the 1x and 2x $role disk image backgrounds could not be joined"
done
# Finder finds a disk image's background picture by volume name, so another
# Sensorium disk image still mounted under the same name would lend its own.
# The version in the name keeps the names apart.
make_dmg "$VIEWER_DMG" "Sensorium.app" "Sensorium $VERSION" "$SCRATCH/dmg-art-viewer"
make_dmg "$HOST_DMG" "Sensorium Host.app" "Sensorium Host $VERSION" "$SCRATCH/dmg-art-host"
verify_dmg "$VIEWER_DMG" "Sensorium.app" Viewer "arm64 x86_64" "$VIEWER_ZIP"
verify_dmg "$HOST_DMG" "Sensorium Host.app" Host "arm64" "$HOST_ZIP"

[ "$LEAF_Viewer" = "$LEAF_Host" ] ||
  die "Sensorium Host: certificate $LEAF_Host differs from the viewer's $LEAF_Viewer; both apps must share one certificate"

(cd "$OUT" && shasum -a 256 "$VIEWER_ZIP" "$HOST_ZIP" "$VIEWER_DMG" "$HOST_DMG" > SHA256SUMS)

# Manifest, in the shape of docs/self-update-design.md section 2.
min_macos_of() {
  RAW="$(plist_value "$1" LSMinimumSystemVersion)"
  if [ -z "$RAW" ]; then
    RAW="$(sed -n 's/.*platforms:.*\.macOS(\.v\([0-9_]*\)).*/\1/p' "$ROOT/Package.swift" | head -n 1 | tr _ .)"
    [ -n "$RAW" ] || die "no LSMinimumSystemVersion in $1 and no macOS platform in Package.swift"
    case "$RAW" in *.*) ;; *) RAW="$RAW.0" ;; esac
  fi
  printf '%s' "$RAW"
}
MIN_VIEWER="$(min_macos_of "$KIT/Sensorium.app")"
MIN_HOST="$(min_macos_of "$KIT/Sensorium Host.app")"
[ "$MIN_VIEWER" = "$MIN_HOST" ] ||
  die "the apps disagree on the minimum macOS: viewer $MIN_VIEWER, host $MIN_HOST"
VIEWER_ID="$(plist_value "$KIT/Sensorium.app" CFBundleIdentifier)"
HOST_ID="$(plist_value "$KIT/Sensorium Host.app" CFBundleIdentifier)"
for value in "$VERSION" "$MIN_VIEWER" "$VIEWER_ID" "$HOST_ID"; do
  case "$value" in
    ''|*[!A-Za-z0-9._+-]*) die "'$value' cannot be written into the manifest" ;;
  esac
done

size_of() { stat -f %z "$1"; }
hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

MANIFEST="$OUT/sensorium-update.json"
{
  printf '{\n  "format": 1,\n  "version": "%s",\n  "minimumMacOS": "%s",\n  "apps": {\n' "$VERSION" "$MIN_VIEWER"
  printf '    "viewer": {\n      "bundleIdentifier": "%s",\n      "file": "%s",\n' "$VIEWER_ID" "$VIEWER_ZIP"
  printf '      "size": %s,\n      "sha256": "%s"\n    },\n' "$(size_of "$OUT/$VIEWER_ZIP")" "$(hash_of "$OUT/$VIEWER_ZIP")"
  printf '    "host": {\n      "bundleIdentifier": "%s",\n      "file": "%s",\n' "$HOST_ID" "$HOST_ZIP"
  printf '      "size": %s,\n      "sha256": "%s"\n    }\n  }\n}\n' "$(size_of "$OUT/$HOST_ZIP")" "$(hash_of "$OUT/$HOST_ZIP")"
} > "$MANIFEST"

swift "$SIGN" sign "$KEY" "$MANIFEST" || die "the manifest could not be signed"
swift "$SIGN" verify "$COMPILED_KEYS" "$MANIFEST" "$MANIFEST.sig" ||
  die "the signature does not verify with the public key compiled into the apps"

# Check each app as the updater will: the manifest's size and hash, then the
# staged app's own --update-self-test.
check_as_updater() {
  ZIP="$1"; APP_NAME="$2"; LABEL="$3"; KEY_NAME="$4"
  [ "$(plutil -extract "apps.$KEY_NAME.size" raw -o - "$MANIFEST")" = "$(size_of "$OUT/$ZIP")" ] ||
    die "$LABEL: the size of $ZIP does not match the manifest"
  [ "$(plutil -extract "apps.$KEY_NAME.sha256" raw -o - "$MANIFEST")" = "$(hash_of "$OUT/$ZIP")" ] ||
    die "$LABEL: the SHA-256 of $ZIP does not match the manifest"
  APP="$SCRATCH/$ZIP/$APP_NAME"
  if [ "${SENSORIUM_SKIP_SELF_TEST:-0}" = 1 ]; then
    printf 'WARNING: SENSORIUM_SKIP_SELF_TEST=1, so %s was not run with --update-self-test. Do not publish a release that skipped it.\n' "$LABEL" >&2
    return 0
  fi
  EXE="$APP/Contents/MacOS/$(plist_value "$APP" CFBundleExecutable)"
  "$EXE" --update-self-test >/dev/null 2>&1 &
  TEST_PID=$!
  (sleep "$SELF_TEST_SECONDS"; kill -KILL "$TEST_PID" 2>/dev/null) >/dev/null 2>&1 &
  WATCHER=$!
  set +e
  wait "$TEST_PID"
  TEST_RC=$?
  set -e
  kill "$WATCHER" 2>/dev/null || true
  wait "$WATCHER" 2>/dev/null || true
  [ "$TEST_RC" = 0 ] ||
    die "$LABEL: the self-test (--update-self-test) exited $TEST_RC or did not finish within ${SELF_TEST_SECONDS}s"
}
check_as_updater "$VIEWER_ZIP" "Sensorium.app" Viewer viewer
check_as_updater "$HOST_ZIP" "Sensorium Host.app" Host host

printf 'Built in %s:\n  %s\n  %s\n  %s\n  %s\n  SHA256SUMS\n  sensorium-update.json\n  sensorium-update.json.sig\n' "$OUT" "$VIEWER_ZIP" "$HOST_ZIP" "$VIEWER_DMG" "$HOST_DMG"
UPLOAD_CMD="gh release upload \"$TAG\" \"$OUT/$VIEWER_ZIP\" \"$OUT/$HOST_ZIP\" \"$OUT/$VIEWER_DMG\" \"$OUT/$HOST_DMG\" \"$OUT/SHA256SUMS\""
MANIFEST_CMD="gh release upload \"$TAG\" \"$MANIFEST\" \"$MANIFEST.sig\""
if [ "$UPLOAD" = 1 ]; then
  gh release upload "$TAG" "$OUT/$VIEWER_ZIP" "$OUT/$HOST_ZIP" "$OUT/$VIEWER_DMG" "$OUT/$HOST_DMG" "$OUT/SHA256SUMS"
  # The manifest goes last so no app reads one whose zips are missing.
  gh release upload "$TAG" "$MANIFEST" "$MANIFEST.sig"
  printf 'Uploaded to %s\n' "$TAG"
else
  printf 'Not uploaded. To upload, rerun with --upload, which runs:\n  %s\n  %s\n' "$UPLOAD_CMD" "$MANIFEST_CMD"
fi
