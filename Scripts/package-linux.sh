#!/bin/sh
# Builds the Fedora package for the viewer.
#
# Everything this writes lands under Artifacts/, which is ignored by git and
# by the public-repository audit, so a build tree can never reach the
# repository. The result is Artifacts/sensorium-<version>-1.<dist>.x86_64.rpm
# and a .sha256 beside it. The package is unsigned: that checksum is what a
# download is checked against.
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

rpmbuild -ba --define "_topdir $TOPDIR" "$TOPDIR/SPECS/sensorium.spec"

built="$(find "$TOPDIR/RPMS" -name "sensorium-$VERSION-1.*.rpm" -type f | head -n 1)"
if [ -z "$built" ]; then
    echo "package-linux: rpmbuild produced no binary package for $VERSION." >&2
    exit 1
fi

cp "$built" "$OUTPUT/$(basename "$built")"
(cd "$OUTPUT" && sha256sum "$(basename "$built")" > "$(basename "$built").sha256")

echo "package-linux: $OUTPUT/$(basename "$built")"
echo "package-linux: $OUTPUT/$(basename "$built").sha256"
