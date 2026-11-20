#!/usr/bin/env bash
#
# Regenerates the Wayland protocol glue in Sources/CWaylandProtocols.
#
# SwiftPM has no build-time code generation for a C target, so the output of
# wayland-scanner is generated once on a machine that has the protocol
# definitions installed and committed. Run this on such a machine whenever the
# protocol list below changes, and record the wayland-protocols version the
# result came from in Sources/CWaylandProtocols/README.md.
#
# Requires: wayland-scanner, the wayland-protocols XML definitions under
# /usr/share/wayland-protocols (override with WAYLAND_PROTOCOLS_DIR), and the
# wlroots protocol definitions under /usr/share/wlr-protocols (override with
# WLR_PROTOCOLS_DIR), which Fedora ships as wlr-protocols-devel.

set -euo pipefail

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$repository/Sources/CWaylandProtocols"
protocols="${WAYLAND_PROTOCOLS_DIR:-/usr/share/wayland-protocols}"
wlr_protocols="${WLR_PROTOCOLS_DIR:-/usr/share/wlr-protocols}"

definitions=(
    "stable/xdg-shell/xdg-shell.xml"
    "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"
    "stable/viewporter/viewporter.xml"
    "staging/fractional-scale/fractional-scale-v1.xml"
    "unstable/relative-pointer/relative-pointer-unstable-v1.xml"
    "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml"
    "unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml"
    "stable/presentation-time/presentation-time.xml"
    "stable/linux-dmabuf/linux-dmabuf-v1.xml"
)

wlr_definitions=(
    "unstable/wlr-layer-shell-unstable-v1.xml"
)

mkdir -p "$target/include"

generate() {
    local xml="$1"
    local name
    name="$(basename "$xml" .xml)"
    wayland-scanner client-header "$xml" "$target/include/$name-client-protocol.h"
    wayland-scanner private-code "$xml" "$target/$name-protocol.c"
    echo "generated $name"
}

for definition in "${definitions[@]}"; do
    generate "$protocols/$definition"
done

for definition in "${wlr_definitions[@]}"; do
    generate "$wlr_protocols/$definition"
done

echo "wayland-scanner $(wayland-scanner --version 2>&1)"
