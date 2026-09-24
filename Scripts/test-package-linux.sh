#!/bin/sh
# Checks the package Scripts/package-linux.sh built, by installing it.
#
# This installs and removes a package, so it runs inside the CI Fedora
# container and nowhere else. It is not a check anyone should run on a machine
# they use.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION)"
DESKTOP_FILE=/usr/share/applications/com.sensorium.viewer.desktop
METAINFO_FILE=/usr/share/metainfo/com.sensorium.viewer.metainfo.xml

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

package="$(find Artifacts -maxdepth 1 -name "sensorium-$VERSION-1.*.rpm" -type f | head -n 1)"
[ -n "$package" ] || fail "no package for $VERSION in Artifacts; run Scripts/package-linux.sh first"

[ -f "$package.sha256" ] || fail "no checksum beside $package"
(cd Artifacts && sha256sum -c "$(basename "$package").sha256" > /dev/null) \
    || fail "the checksum beside $package does not match it"

dnf install -y "$package"

# The two files a desktop environment reads before anything is ever launched.
desktop-file-validate "$DESKTOP_FILE" || fail "the installed desktop entry is not valid"
appstreamcli validate --no-net "$METAINFO_FILE" || fail "the installed metainfo is not valid"

# Small, large, and one in between: a theme picks the nearest size it has.
for size in 48 256 22; do
    icon="/usr/share/icons/hicolor/${size}x${size}/apps/com.sensorium.viewer.png"
    [ -f "$icon" ] || fail "no icon installed at ${size}x${size}"
done

# No scriptlet registers the URL scheme: the file trigger desktop-file-utils
# owns is what rebuilds this cache, and this proves it fired.
grep "x-scheme-handler/sensorium" /usr/share/applications/mimeinfo.cache \
    | grep -q "com.sensorium.viewer.desktop" \
    || fail "sensorium:// links are not registered to the installed desktop entry"

# The one thing the binary is asked to do here: answer without a display.
usage="$(Sensorium --help)" || fail "Sensorium --help did not exit 0"
echo "$usage" | grep -q "^usage: Sensorium " || fail "Sensorium --help printed no usage"

requires="$(rpm -qR sensorium | sed 's/(.*//' | grep '^lib.*\.so' | sort -u)"

# Every system library the viewer links against, derived from the modulemaps
# themselves rather than listed here, so a new dependency cannot be added
# without this noticing. `va` is also linked directly by CVASurfaceExport.
linked="$(sed -n 's/^[[:space:]]*link "\(.*\)"$/\1/p' Sources/C*/module.modulemap; echo va)"
for name in $(echo "$linked" | sort -u); do
    echo "$requires" | grep -q "^lib${name}\.so" \
        || fail "the package does not require lib${name}.so, which a modulemap links against"
done

# Fedora's swift-lang package ships no static standard library, so the
# runtime is dynamic and comes from swift-lang-runtime. These three sonames
# are what pulls that package in; a package missing them would have nothing
# to run against.
for runtime in libswiftCore.so libFoundation.so libdispatch.so; do
    echo "$requires" | grep -q "^${runtime}" \
        || fail "the package does not require ${runtime}, so nothing pulls in the Swift runtime"
done

# What is left has to be the Swift runtime, the C runtime, or a library the
# GTK stack pulls in on its own behalf. Anything else is a dependency nobody
# declared.
allowed="libc.so libm.so libdl.so libpthread.so librt.so libatomic.so libz.so
libstdc++.so libgcc_s.so libcairo-gobject.so libgdk_pixbuf-2.0.so libgio-2.0.so
libgraphene-1.0.so libharfbuzz.so libvulkan.so
libswift libFoundation libdispatch libBlocksRuntime"
for entry in $requires; do
    known=no
    for name in $(echo "$linked" | sort -u); do
        case "$entry" in "lib${name}.so"*) known=yes ;; esac
    done
    for name in $allowed; do
        case "$entry" in "${name}"*) known=yes ;; esac
    done
    [ "$known" = yes ] || fail "the package requires $entry, which nothing in this tree declares"
done

rpm -q --recommends sensorium | grep -q "mesa-va-drivers-freeworld" \
    || fail "the package does not recommend the VA-API driver Fedora leaves out"

installed_version="$(rpm -q --queryformat '%{VERSION}' sensorium)"
[ "$installed_version" = "$VERSION" ] \
    || fail "the package says $installed_version, the VERSION file says $VERSION"

owned="$(rpm -ql sensorium)"
dnf remove -y sensorium
for path in $owned; do
    if [ -e "$path" ]; then
        fail "removing the package left $path behind"
    fi
done

echo "PASS: the Fedora package installs, registers, runs, asks for the right libraries, and removes cleanly"
