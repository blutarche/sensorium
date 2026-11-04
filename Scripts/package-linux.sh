#!/bin/sh
# Builds the Fedora package for the viewer.
#
# Everything this writes lands under Artifacts/, which is ignored by git and
# by the public-repository audit, so a build tree can never reach the
# repository. The result is Artifacts/sensorium-<version>-1.<dist>.x86_64.rpm
# and a .sha256 beside it. The package is unsigned: that checksum is what a
# download is checked against. The viewer binary the package installs also
# goes to Artifacts/Sensorium-<version>-linux-x86_64.tar.gz, with its own
# .sha256, which is what the viewer updates itself from.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION)"
TOPDIR="$PWD/Artifacts/rpmbuild"
OUTPUT="$PWD/Artifacts"

if ! command -v rpmbuild > /dev/null 2>&1; then
    echo "package-linux: rpmbuild is not installed." >&2
    echo "package-linux: this runs in the CI Fedora container, which installs rpm-build for it." >&2
    exit 1
fi

rm -rf "$TOPDIR"
mkdir -p "$TOPDIR/BUILD" "$TOPDIR/RPMS" "$TOPDIR/SOURCES" "$TOPDIR/SPECS" "$TOPDIR/SRPMS" "$OUTPUT"

# The worktree as it stands, named the way %autosetup expects to find it.
# .build and Artifacts are this machine's, not the source; .git is history.
tar czf "$TOPDIR/SOURCES/sensorium-$VERSION.tar.gz" \
    --exclude=./.build \
    --exclude=./.git \
    --exclude=./Artifacts \
    --transform "s,^\.,sensorium-$VERSION," \
    .

sed "s/@VERSION@/$VERSION/" Packaging/linux/sensorium.spec.in > "$TOPDIR/SPECS/sensorium.spec"

# SwiftPM puts the system Swift runtime directory before $ORIGIN in RUNPATH.
# The package installs no libraries beside Sensorium, so allow that ordering
# while keeping every other RPM runpath check enabled.
QA_RPATHS=0x0008 rpmbuild -ba --define "_topdir $TOPDIR" "$TOPDIR/SPECS/sensorium.spec"

built="$(find "$TOPDIR/RPMS" -name "sensorium-$VERSION-1.*.rpm" -type f | head -n 1)"
if [ -z "$built" ]; then
    echo "package-linux: rpmbuild produced no binary package for $VERSION." >&2
    exit 1
fi

cp "$built" "$OUTPUT/$(basename "$built")"
(cd "$OUTPUT" && sha256sum "$(basename "$built")" > "$(basename "$built").sha256")

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

echo "package-linux: $OUTPUT/$(basename "$built")"
echo "package-linux: $OUTPUT/$(basename "$built").sha256"
