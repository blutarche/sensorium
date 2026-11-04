#!/bin/sh
# Signs the Linux viewer's update manifest and uploads it. Run by the
# maintainer, on the machine that holds the update key, after the release-linux
# workflow has attached Sensorium-<version>-linux-x86_64.tar.gz to the release.
#
#   Scripts/sign-linux-update.sh [--dry-run] v<version>
#
# Downloads the tarball, hashes it, writes sensorium-update-linux-x86_64.json
# (docs/self-update-design.md section 11.2), signs its exact bytes with the key
# Scripts/release-macos.sh uses (SENSORIUM_UPDATE_KEY, else
# $HOME/.sensorium-release/update-key), checks the signature against the public
# key compiled into the apps, and uploads the signature and then the manifest.
# --dry-run does everything but the upload and keeps the files it wrote.
# SENSORIUM_LINUX_UPDATE_DIR names an empty folder to work in; the script
# removes only a folder it made itself.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
SIGN="$ROOT/Scripts/sign-update.swift"
KEY="${SENSORIUM_UPDATE_KEY:-$HOME/.sensorium-release/update-key}"
MANIFEST_NAME="sensorium-update-linux-x86_64.json"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'usage: %s [--dry-run] v<version>\n' "$0" >&2
    exit 2
}

DRY_RUN=0
TAG=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) usage ;;
        *) [ -z "$TAG" ] || usage; TAG="$arg" ;;
    esac
done
[ -n "$TAG" ] || usage

case "$TAG" in
    v?*) ;;
    *) die "the tag must look like v$VERSION, with the leading v" ;;
esac
[ "${TAG#v}" = "$VERSION" ] ||
    die "the tag is $TAG but VERSION is $VERSION. Check out the release's commit, or fix the tag."

TARBALL="Sensorium-$VERSION-linux-x86_64.tar.gz"

[ -f "$KEY" ] || die "the update key file $KEY does not exist. Set SENSORIUM_UPDATE_KEY to your key file."
COMPILED_FILE="$ROOT/Sources/SensoriumUpdate/UpdatePublicKey.swift"
[ -f "$COMPILED_FILE" ] || die "$COMPILED_FILE is missing, so the key compiled into the apps is unknown"
COMPILED_KEYS="$(grep -Eo '"[A-Za-z0-9+/]{43}="' "$COMPILED_FILE" | tr -d '"' || true)"
[ -n "$COMPILED_KEYS" ] && [ "$(printf '%s\n' "$COMPILED_KEYS" | wc -l | tr -d ' ')" = 1 ] ||
    die "$COMPILED_FILE must hold exactly one base64 string of 32 bytes"

if [ -n "${SENSORIUM_LINUX_UPDATE_DIR:-}" ]; then
    WORK="$SENSORIUM_LINUX_UPDATE_DIR"
    [ -d "$WORK" ] && [ -z "$(ls -A "$WORK")" ] || die "$WORK must be an existing, empty folder"
    OWN_WORK=0
else
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/sensorium-linux-update.XXXXXX")"
    OWN_WORK=1
fi
KEEP_WORK=0
cleanup() {
    if [ "$OWN_WORK" = 1 ] && [ "$KEEP_WORK" = 0 ]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v gh > /dev/null 2>&1 || die "gh is not installed, so the tarball cannot be downloaded"
(cd "$ROOT" && gh release download "$TAG" --pattern "$TARBALL" --dir "$WORK") ||
    die "the tarball $TARBALL could not be downloaded from release $TAG. Has the release-linux workflow finished?"
[ -f "$WORK/$TARBALL" ] || die "release $TAG has no tarball named $TARBALL"

sh "$ROOT/Scripts/test-linux-update-archive.sh" "$WORK/$TARBALL" ||
    die "$TARBALL is not the archive the viewer expects, so nothing was signed"

SIZE="$(wc -c < "$WORK/$TARBALL" | tr -d ' ')"
if command -v sha256sum > /dev/null 2>&1; then
    DIGEST="$(sha256sum "$WORK/$TARBALL" | cut -d' ' -f1)"
else
    DIGEST="$(shasum -a 256 "$WORK/$TARBALL" | cut -d' ' -f1)"
fi
case "$VERSION" in
    ''|*[!A-Za-z0-9._+-]*) die "'$VERSION' cannot be written into the manifest" ;;
esac

# Compact, with the keys in a fixed order, and no trailing newline: the
# signature covers these exact bytes.
MANIFEST="$WORK/$MANIFEST_NAME"
printf '{"format":1,"version":"%s","file":"%s","size":%s,"sha256":"%s"}' \
    "$VERSION" "$TARBALL" "$SIZE" "$DIGEST" > "$MANIFEST"

KEY_PUBLIC="$(swift "$SIGN" public-key "$KEY")" || die "the update key file $KEY cannot be used"
[ "$KEY_PUBLIC" = "$COMPILED_KEYS" ] ||
    die "the public key of $KEY does not match the public key compiled into the apps; signing with it would make every installed viewer reject the update"
swift "$SIGN" sign "$KEY" "$MANIFEST" || die "the manifest could not be signed"
swift "$SIGN" verify "$COMPILED_KEYS" "$MANIFEST" "$MANIFEST.sig" ||
    die "the signature does not verify with the public key compiled into the apps"

# The signature goes first: a viewer that finds a manifest must find its
# signature already there.
SIG_CMD="gh release upload \"$TAG\" \"$MANIFEST.sig\" --clobber"
MANIFEST_CMD="gh release upload \"$TAG\" \"$MANIFEST\" --clobber"
if [ "$DRY_RUN" = 1 ]; then
    KEEP_WORK=1
    printf 'Dry run, not uploaded. The files are in %s. Without --dry-run this runs:\n  %s\n  %s\n' "$WORK" "$SIG_CMD" "$MANIFEST_CMD"
else
    printf 'Uploading with:\n  %s\n  %s\n' "$SIG_CMD" "$MANIFEST_CMD"
    (cd "$ROOT" && gh release upload "$TAG" "$MANIFEST.sig" --clobber)
    (cd "$ROOT" && gh release upload "$TAG" "$MANIFEST" --clobber)
    printf 'Uploaded to %s\n' "$TAG"
fi
