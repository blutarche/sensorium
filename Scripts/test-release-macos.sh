#!/bin/sh
# Exercises Scripts/release-macos.sh in a scratch copy of the repository layout.
# The real packager is replaced by a stub that assembles tiny signed apps, `gh`
# is a logging stub, and `codesign -d -r-` is faked so a certificate leaf can be
# present without touching the keychain. The update key is generated into the
# scratch folder, and the compiled public key is a fixture. Nothing here builds
# Sensorium, signs with a real identity, or reaches the network.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELEASE="$ROOT/Scripts/release-macos.sh"
[ -f "$RELEASE" ] || { echo "Scripts/release-macos.sh is missing" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sensorium-release-test.XXXXXX")"
MOUNTS=""
cleanup() {
  for mnt in $MOUNTS; do hdiutil detach -force "$mnt" >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

REPO="$WORK/repo"
STUBS="$WORK/stubs"
mkdir -p "$REPO/Scripts" "$STUBS"
cp "$RELEASE" "$REPO/Scripts/release-macos.sh"
cp "$ROOT/Scripts/sign-update.swift" "$REPO/Scripts/sign-update.swift"
printf '9.8.7\n' > "$REPO/VERSION"
printf '// swift-tools-version: 6.0\nlet package = Package(\n    name: "x",\n    platforms: [.macOS(.v13)],\n)\n' > "$REPO/Package.swift"

SIGN="$REPO/Scripts/sign-update.swift"
KEYS="$WORK/keys"
mkdir -p "$KEYS" "$REPO/Sources/SensoriumUpdate"
KEY="$KEYS/update-key"
PUB="$(swift "$SIGN" generate "$KEY")"
OTHER_PUB="$(swift "$SIGN" generate "$KEYS/other-key")"
cat > "$REPO/Sources/SensoriumUpdate/UpdatePublicKey.swift" <<SWIFT
enum UpdatePublicKey {
    static let note = "not a key"
    static let base64 = "$PUB"
}
SWIFT
export SENSORIUM_UPDATE_KEY="$KEY"
export SENSORIUM_RELEASE_CERT_LEAF='H"aaaa"'
unset SENSORIUM_SKIP_SELF_TEST

# The self-test exit code comes from STUB_SELFTEST_RC; "hang" never returns.
cat > "$WORK/main.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--update-self-test") == 0) {
    const char *log = getenv("STUB_SELFTEST_LOG");
    if (log) { FILE *f = fopen(log, "a"); if (f) { fprintf(f, "ran\n"); fclose(f); } }
    const char *rc = getenv("STUB_SELFTEST_RC");
    if (rc && strcmp(rc, "hang") == 0) sleep(60);
    return rc ? atoi(rc) : 0;
  }
  return 0;
}
C
cc -arch x86_64 -arch arm64 -o "$WORK/universal" "$WORK/main.c"
cc -arch arm64 -o "$WORK/arm64" "$WORK/main.c"

# Stand-in for package-apps.sh. STUB_KIT_VERSION overrides the version written
# into the plists; STUB_PACKAGER_LOG records the ad hoc setting it was given.
cat > "$REPO/Scripts/package-apps.sh" <<STUB
#!/bin/sh
set -eu
ROOT="\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd)"
printf '%s\n' "\${SENSORIUM_ALLOW_ADHOC-unset}" > "$WORK/packager-adhoc"
V="\${STUB_KIT_VERSION:-\$(tr -d '[:space:]' < "\$ROOT/VERSION")}"
KIT="\$ROOT/Artifacts/Sensorium"
rm -rf "\$KIT"
make_app() {
  APP="\$KIT/\$1.app"; EXE="\$2"; ID="\$3"; BIN="\$4"; MIN="\$5"
  mkdir -p "\$APP/Contents/MacOS"
  cp "\$BIN" "\$APP/Contents/MacOS/\$EXE"
  cat > "\$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>\$EXE</string>
<key>CFBundleIdentifier</key><string>\$ID</string>
<key>CFBundleShortVersionString</key><string>\$V</string>
\${MIN:+<key>LSMinimumSystemVersion</key><string>\$MIN</string>}
</dict></plist>
PLIST
  codesign --force --sign - "\$APP" >/dev/null 2>&1
}
make_app Sensorium Sensorium com.sensorium.viewer "$WORK/universal" "\${STUB_MIN_OS:-}"
make_app "Sensorium Host" SensoriumHost com.sensorium.host "$WORK/arm64" "\${STUB_HOST_MIN_OS:-\${STUB_MIN_OS:-}}"
if [ -n "\${STUB_OUTSIDE_LINK:-}" ]; then
  mkdir -p "\$KIT/Sensorium.app/Contents/Resources"
  ln -s /etc "\$KIT/Sensorium.app/Contents/Resources/escape"
  codesign --force --sign - "\$KIT/Sensorium.app" >/dev/null 2>&1
fi
STUB
chmod +x "$REPO/Scripts/package-apps.sh" "$REPO/Scripts/release-macos.sh"

cat > "$STUBS/gh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/gh.log"
case "\$1 \$2" in
  "release view") exit "\${GH_VIEW_RC:-0}" ;;
esac
exit 0
STUB
cat > "$STUBS/codesign" <<STUB
#!/bin/sh
case " \$* " in
  *" -r- "*)
    LEAF="\${STUB_LEAF:-aaaa}"
    case "\$*" in *"Host.app"*) LEAF="\${STUB_HOST_LEAF:-\$LEAF}" ;; esac
    [ "\${STUB_NO_LEAF:-0}" = 1 ] && exec /usr/bin/codesign "\$@"
    printf 'designated => identifier "x" and certificate leaf = H"%s"\n' "\$LEAF" >&2
    ;;
  *) exec /usr/bin/codesign "\$@" ;;
esac
STUB
chmod +x "$STUBS/gh" "$STUBS/codesign"

run_release() {
  PATH="$STUBS:$PATH" "$REPO/Scripts/release-macos.sh" "$@" > "$WORK/out" 2>&1
}
fail() { echo "FAIL: $1" >&2; sed 's/^/  | /' "$WORK/out" >&2; exit 1; }

REL="$REPO/Artifacts/release"
rm -f "$WORK/gh.log" "$WORK/packager-adhoc" "$WORK/selftest.log"
export STUB_SELFTEST_LOG="$WORK/selftest.log"

# Per-call variables are set inside a subshell so they cannot leak into later
# runs; some shells keep a prefix assignment on a function call.
# Happy path. The caller's ad hoc permission must not reach the packager.
(SENSORIUM_ALLOW_ADHOC=1 run_release) || fail "release should succeed with a certificate leaf"
[ "$(cat "$WORK/packager-adhoc")" = "0" ] || fail "packager must run with SENSORIUM_ALLOW_ADHOC=0"
[ -f "$REL/Sensorium-9.8.7.zip" ] || fail "viewer zip name"
[ -f "$REL/Sensorium-Host-9.8.7.zip" ] || fail "host zip name"
[ -f "$REL/Sensorium-9.8.7.dmg" ] || fail "viewer disk image name"
[ -f "$REL/Sensorium-Host-9.8.7.dmg" ] || fail "host disk image name"
[ "$(ls -A "$REL" | wc -l | tr -d ' ')" = "7" ] || fail "release folder should hold two zips, two disk images, SHA256SUMS, the manifest and its signature"
for zip in Sensorium-9.8.7.zip Sensorium-Host-9.8.7.zip; do
  mkdir "$WORK/unz-$zip"
  ditto -x -k "$REL/$zip" "$WORK/unz-$zip"
  [ "$(ls -A "$WORK/unz-$zip" | wc -l | tr -d ' ')" = "1" ] || fail "$zip should hold exactly one item"
done
[ -d "$WORK/unz-Sensorium-9.8.7.zip/Sensorium.app" ] || fail "viewer zip should hold Sensorium.app"
[ -d "$WORK/unz-Sensorium-Host-9.8.7.zip/Sensorium Host.app" ] || fail "host zip should hold Sensorium Host.app"
# Each disk image holds the app and a link to /Applications, nothing else.
check_image() {
  DMG="$1"; APP_NAME="$2"
  MNT="$WORK/mnt-$DMG"
  mkdir "$MNT"
  MOUNTS="$MOUNTS $MNT"
  hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$REL/$DMG" >/dev/null || fail "$DMG should attach"
  [ "$(ls "$MNT" | wc -l | tr -d ' ')" = "2" ] || fail "$DMG should show exactly two items"
  [ -d "$MNT/$APP_NAME" ] && [ ! -L "$MNT/$APP_NAME" ] || fail "$DMG should hold $APP_NAME as a directory"
  [ -L "$MNT/Applications" ] || fail "$DMG should hold an Applications link"
  [ "$(readlink "$MNT/Applications")" = "/Applications" ] || fail "$DMG Applications link should point to /Applications"
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$MNT/$APP_NAME/Contents/Info.plist")" = "9.8.7" ] || fail "$DMG app version should be 9.8.7"
  hdiutil detach "$MNT" >/dev/null || fail "$DMG should detach"
}
check_image Sensorium-9.8.7.dmg "Sensorium.app"
check_image Sensorium-Host-9.8.7.dmg "Sensorium Host.app"
[ "$(wc -l < "$REL/SHA256SUMS" | tr -d ' ')" = "4" ] || fail "SHA256SUMS should list four files"
(cd "$REL" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail "SHA256SUMS should verify from inside the release folder"
grep -q '/' "$REL/SHA256SUMS" && fail "SHA256SUMS should list file names only"
[ ! -e "$WORK/gh.log" ] || fail "nothing may reach gh without --upload"
grep -qF 'gh release upload "v9.8.7"' "$WORK/out" || fail "output should print the upload command"

# The manifest has the exact shape, key order, sizes and hashes of the design.
MANIFEST="$REL/sensorium-update.json"
size_of() { stat -f %z "$1"; }
hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
{
  printf '{\n  "format": 1,\n  "version": "9.8.7",\n  "minimumMacOS": "13.0",\n  "apps": {\n'
  printf '    "viewer": {\n      "bundleIdentifier": "com.sensorium.viewer",\n      "file": "Sensorium-9.8.7.zip",\n'
  printf '      "size": %s,\n      "sha256": "%s"\n    },\n' "$(size_of "$REL/Sensorium-9.8.7.zip")" "$(hash_of "$REL/Sensorium-9.8.7.zip")"
  printf '    "host": {\n      "bundleIdentifier": "com.sensorium.host",\n      "file": "Sensorium-Host-9.8.7.zip",\n'
  printf '      "size": %s,\n      "sha256": "%s"\n    }\n  }\n}\n' "$(size_of "$REL/Sensorium-Host-9.8.7.zip")" "$(hash_of "$REL/Sensorium-Host-9.8.7.zip")"
} > "$WORK/expected-manifest.json"
cmp -s "$WORK/expected-manifest.json" "$MANIFEST" || { diff "$WORK/expected-manifest.json" "$MANIFEST" >&2 || true; fail "manifest must match the design's shape, sizes and hashes"; }
[ "$(plutil -extract format raw -o - "$MANIFEST")" = "1" ] || fail "manifest must parse as JSON"

# The signature is one base64 line, verifies with the fixture key, and fails
# after any change to the manifest.
[ "$(wc -l < "$MANIFEST.sig" | tr -d ' ')" = "1" ] || fail "signature must be one line"
swift "$SIGN" verify "$PUB" "$MANIFEST" "$MANIFEST.sig" || fail "signature must verify with the fixture public key"
swift "$SIGN" verify "$OTHER_PUB" "$MANIFEST" "$MANIFEST.sig" 2>/dev/null && fail "signature must not verify with another key"
cp "$MANIFEST" "$WORK/tampered.json"
printf ' ' >> "$WORK/tampered.json"
swift "$SIGN" verify "$PUB" "$WORK/tampered.json" "$MANIFEST.sig" 2>/dev/null && fail "a tampered manifest must not verify"

# Both apps were run with --update-self-test.
[ "$(wc -l < "$WORK/selftest.log" | tr -d ' ')" = "2" ] || fail "each app must run --update-self-test once"

# minimumMacOS comes from the apps when they set it, and they must agree.
(STUB_MIN_OS=14.2 run_release) || fail "release should succeed with LSMinimumSystemVersion set"
grep -q '"minimumMacOS": "14.2"' "$MANIFEST" || fail "minimumMacOS should come from the apps' Info.plist"
(STUB_MIN_OS=14.2 STUB_HOST_MIN_OS=13.0 run_release) && fail "apps that disagree on the minimum macOS must be refused"
grep -qF "minimum" "$WORK/out" || fail "minimum macOS disagreement should be named"

# A symbolic link that points outside an app is refused.
(STUB_OUTSIDE_LINK=1 run_release) && fail "a symlink pointing outside the app must be refused"
grep -qF "symbolic link" "$WORK/out" || fail "symlink refusal should be named"

# Key file refusals.
(SENSORIUM_UPDATE_KEY="$WORK/no-such-key" run_release) && fail "a missing key file must be refused"
grep -qF "no-such-key" "$WORK/out" || fail "missing key refusal should name the file"
cp "$KEY" "$KEYS/group-key"; chmod 640 "$KEYS/group-key"
(SENSORIUM_UPDATE_KEY="$KEYS/group-key" run_release) && fail "a group-readable key must be refused"
grep -qF "group or others" "$WORK/out" || fail "key permission refusal should say why"
cp "$KEY" "$KEYS/world-key"; chmod 604 "$KEYS/world-key"
(SENSORIUM_UPDATE_KEY="$KEYS/world-key" run_release) && fail "a world-readable key must be refused"
(SENSORIUM_UPDATE_KEY="$KEYS/other-key" run_release) && fail "a key that does not match the compiled key must be refused"
grep -qF "compiled" "$WORK/out" || fail "key mismatch should name the compiled key"

# The release certificate is pinned. A leaf other than the pinned one is refused.
(SENSORIUM_RELEASE_CERT_LEAF='H"bbbb"' run_release) && fail "an unpinned certificate leaf must be refused"
grep -qF "pinned" "$WORK/out" || fail "pin refusal should say the certificate is pinned"
(unset SENSORIUM_RELEASE_CERT_LEAF; run_release) && fail "the built-in pin must refuse a different certificate"
grep -qF '87558db5f8fd5d678dfa2a503aaf4b39d49ff515' "$RELEASE" || fail "release script must pin the release certificate"

# A self-test that does not exit 0 is refused, and so is one that hangs.
(STUB_SELFTEST_RC=3 run_release) && fail "a failing self-test must be refused"
grep -qF "self-test" "$WORK/out" || fail "self-test refusal should be named"
(STUB_SELFTEST_RC=hang SENSORIUM_SELF_TEST_SECONDS=1 run_release) && fail "a hanging self-test must be refused"
grep -qF "self-test" "$WORK/out" || fail "hung self-test refusal should be named"
(STUB_SELFTEST_RC=3 SENSORIUM_SKIP_SELF_TEST=1 run_release) || fail "SENSORIUM_SKIP_SELF_TEST=1 should skip the self-test"
grep -qF "WARNING" "$WORK/out" || fail "skipping the self-test must print a warning"

# An ad hoc build has no certificate leaf and must be refused.
(STUB_NO_LEAF=1 run_release) && fail "ad hoc build must be refused"
grep -qF "certificate" "$WORK/out" || fail "ad hoc refusal should name the certificate check"

# The two apps must share one certificate leaf.
(STUB_HOST_LEAF=bbbb run_release) && fail "different leaves must be refused"
grep -qF "Host:" "$WORK/out" || fail "leaf mismatch should name the app"

# A kit whose version differs from VERSION must be refused.
(STUB_KIT_VERSION=1.2.3 run_release) && fail "version mismatch must be refused"
grep -qF "version" "$WORK/out" || fail "version mismatch should be named"

# Upload requires an existing release and never clobbers.
rm -f "$WORK/gh.log"
(GH_VIEW_RC=1 run_release --upload) && fail "--upload must fail when the release does not exist"
grep -qF "v9.8.7" "$WORK/out" || fail "missing-release message should name the tag"
! grep -q 'release upload' "$WORK/gh.log" || fail "no upload when the release is missing"
rm -f "$WORK/gh.log"
run_release --upload || fail "--upload should succeed when the release exists"
[ "$(grep -c '^release upload' "$WORK/gh.log")" = "2" ] || fail "upload should be two gh calls"
grep '^release upload' "$WORK/gh.log" | sed -n 1p | grep -q '^release upload v9.8.7 .*Sensorium-9.8.7.zip .*Sensorium-Host-9.8.7.zip .*Sensorium-9.8.7.dmg .*Sensorium-Host-9.8.7.dmg .*SHA256SUMS$' || fail "first upload call carries the zips, the disk images and SHA256SUMS"
grep '^release upload' "$WORK/gh.log" | sed -n 1p | grep -q 'sensorium-update' && fail "the manifest must not be in the first upload call"
grep '^release upload' "$WORK/gh.log" | sed -n 2p | grep -q '^release upload v9.8.7 .*sensorium-update.json .*sensorium-update.json.sig$' || fail "last upload call carries the manifest and its signature"
grep '^release upload' "$WORK/gh.log" | sed -n 2p | grep -q '\.zip\|\.dmg' && fail "the last upload call must hold only the manifest and signature"
! grep -q -- '--clobber' "$WORK/gh.log" || fail "upload must not clobber"

run_release --bogus && fail "unknown arguments must be refused"

printf 'PASS: release zips, disk images, manifest, signature, checks and upload gate\n'
