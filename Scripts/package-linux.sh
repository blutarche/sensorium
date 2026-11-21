#!/bin/sh
# Builds the Fedora viewer package, or the host package with --host.
# Each RPM lands in Artifacts/ with a .sha256 beside it. The viewer build
# also writes the archive the viewer updates itself from.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION)"
TOPDIR="$PWD/Artifacts/rpmbuild"
OUTPUT="$PWD/Artifacts"
PACKAGE=sensorium

usage() {
    echo "usage: $0 [--host]" >&2
    exit 2
}

case "$#" in
    0) ;;
    1)
        [ "$1" = --host ] || usage
        PACKAGE=sensorium-host
        TOPDIR="$TOPDIR-host"
        ;;
    *) usage ;;
esac

if ! command -v rpmbuild > /dev/null 2>&1; then
    echo "package-linux: rpmbuild is not installed." >&2
    echo "package-linux: this runs in the CI Fedora container, which installs rpm-build for it." >&2
    exit 1
fi

rm -rf "$TOPDIR"
mkdir -p "$TOPDIR/BUILD" "$TOPDIR/RPMS" "$TOPDIR/SOURCES" "$TOPDIR/SPECS" "$TOPDIR/SRPMS" "$OUTPUT"

# Package the working files without any ignored build output or local data.
git -c "safe.directory=$ROOT" ls-files -z --cached --others --exclude-standard --deduplicate > "$TOPDIR/source-files"
tar czf "$TOPDIR/SOURCES/sensorium-$VERSION.tar.gz" --null --no-recursion \
    --transform "flags=rh;s,^,sensorium-$VERSION/," --files-from="$TOPDIR/source-files"

sed "s/@VERSION@/$VERSION/" "Packaging/linux/$PACKAGE.spec.in" > "$TOPDIR/SPECS/$PACKAGE.spec"

# SwiftPM puts the system Swift runtime directory before $ORIGIN in RUNPATH.
# The package installs no libraries beside its executable, so allow that ordering
# while keeping every other RPM runpath check enabled.
QA_RPATHS=0x0008 rpmbuild -ba --define "_topdir $TOPDIR" "$TOPDIR/SPECS/$PACKAGE.spec"

built="$(find "$TOPDIR/RPMS" -name "$PACKAGE-$VERSION-1.*.rpm" -type f | head -n 1)"
if [ -z "$built" ]; then
    echo "package-linux: rpmbuild produced no binary package for $VERSION." >&2
    exit 1
fi

cp "$built" "$OUTPUT/$(basename "$built")"
(cd "$OUTPUT" && sha256sum "$(basename "$built")" > "$(basename "$built").sha256")

echo "package-linux: $OUTPUT/$(basename "$built")"
echo "package-linux: $OUTPUT/$(basename "$built").sha256"

[ "$PACKAGE" = sensorium ] || exit 0

# The update archive holds the binary taken out of the package, so it is the
# one the package test installs and runs, and nothing is built twice.
for tool in rpm2cpio cpio; do
    command -v "$tool" > /dev/null 2>&1 || { echo "package-linux: $tool is not installed." >&2; exit 1; }
done
UNPACKED="$TOPDIR/unpacked"
rm -rf "$UNPACKED"
mkdir -p "$UNPACKED"
rpm2cpio "$built" | (cd "$UNPACKED" && cpio --quiet -idm ./usr/bin/Sensorium)
sh "$ROOT/Scripts/make-linux-update-archive.sh" "$UNPACKED/usr/bin/Sensorium" "$OUTPUT"
