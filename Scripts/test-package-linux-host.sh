#!/bin/sh
# Installs and removes the host RPM in a disposable Fedora container.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION)"
DESKTOP_FILE=/usr/share/applications/com.sensorium.host.desktop
METAINFO_FILE=/usr/share/metainfo/com.sensorium.host.metainfo.xml

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

package="$(find Artifacts -maxdepth 1 -name "sensorium-host-$VERSION-1.*.rpm" -type f | head -n 1)"
[ -n "$package" ] || fail "no host package for $VERSION in Artifacts; run Scripts/package-linux.sh --host first"
(cd Artifacts && sha256sum -c "$(basename "$package").sha256")

dnf install -y "$package"

desktop-file-validate "$DESKTOP_FILE"
appstreamcli validate --no-net "$METAINFO_FILE"
grep -qx 'Exec=sensorium-host' "$DESKTOP_FILE" || fail "the launcher does not start Sensorium Host"
grep -qx 'Icon=com.sensorium.host' "$DESKTOP_FILE" || fail "the launcher does not use the host icon"
for size in 16 22 24 32 48 64 128 256 512; do
    [ -f "/usr/share/icons/hicolor/${size}x${size}/apps/com.sensorium.host.png" ] \
        || fail "no host icon installed at ${size}x${size}"
done

usage="$(sensorium-host --help)" || fail "sensorium-host --help did not exit 0"
printf '%s\n' "$usage" | grep -q '^usage: sensorium-host' || fail "sensorium-host --help printed no usage"

requires="$(rpm -qR sensorium-host | sed 's/(.*//' | sort -u)"
for name in libswiftCore.so libFoundation.so libgtk-4.so.1 libpipewire-0.3.so.0 libssl.so.3 pipewire xdg-desktop-portal-kde; do
    printf '%s\n' "$requires" | grep -Fxq "$name" || fail "the host package does not require $name"
done
[ "$(rpm -q --queryformat '%{VERSION}' sensorium-host)" = "$VERSION" ] || fail "the host package version differs from VERSION"

owned="$(rpm -ql sensorium-host)"
dnf remove -y sensorium-host
for path in $owned; do
    if [ ! -d "$path" ] && { [ -e "$path" ] || [ -L "$path" ]; }; then
        fail "removing the host package left $path behind"
    fi
done

echo "PASS: the Fedora host package installs, has a valid launcher, runs, and removes cleanly"
