#!/bin/sh
# Packs the Linux viewer binary into the archive the viewer updates itself from.
#
#   Scripts/make-linux-update-archive.sh <binary> <output directory>
#
# Writes Sensorium-<version>-linux-x86_64.tar.gz and a .sha256 beside it. The
# archive holds one regular file, Sensorium, mode 0755, with no owner and a
# fixed time, so the same binary always packs to the same bytes. The time is
# SOURCE_DATE_EPOCH when set, else the commit time of HEAD. Needs GNU tar.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

die() {
    echo "make-linux-update-archive: $*" >&2
    exit 1
}

[ $# -eq 2 ] || { echo "usage: $0 <binary> <output directory>" >&2; exit 2; }
BINARY="$1"
OUTPUT="$2"
[ -f "$BINARY" ] || die "no binary at $BINARY"
[ -d "$OUTPUT" ] || die "$OUTPUT is not a directory"
tar --version 2> /dev/null | grep -q "GNU tar" || die "this needs GNU tar for a reproducible archive"

EPOCH="${SOURCE_DATE_EPOCH:-}"
if [ -z "$EPOCH" ]; then
    # The checkout may belong to another user, as in a CI container.
    EPOCH="$(git -C "$ROOT" -c "safe.directory=$ROOT" log -1 --format=%ct 2> /dev/null || true)"
fi
case "$EPOCH" in
    ''|*[!0-9]*) die "set SOURCE_DATE_EPOCH; the commit time could not be read" ;;
esac

NAME="Sensorium-$VERSION-linux-x86_64.tar.gz"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sensorium-update-archive.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
install -m 0755 "$BINARY" "$STAGE/Sensorium"

# Two steps rather than a pipe, so a failing tar stops the script. gzip -n
# leaves the file name and time out of the header.
tar --create --format=gnu --owner=0 --group=0 --numeric-owner --sort=name \
    --mtime="@$EPOCH" --file="$STAGE/archive.tar" -C "$STAGE" Sensorium
gzip -n < "$STAGE/archive.tar" > "$STAGE/$NAME"

cp "$STAGE/$NAME" "$OUTPUT/$NAME"
if command -v sha256sum > /dev/null 2>&1; then
    (cd "$OUTPUT" && sha256sum "$NAME" > "$NAME.sha256")
else
    (cd "$OUTPUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
fi

echo "make-linux-update-archive: $OUTPUT/$NAME"
echo "make-linux-update-archive: $OUTPUT/$NAME.sha256"
