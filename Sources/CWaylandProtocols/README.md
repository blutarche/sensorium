# CWaylandProtocols

The client-side glue for the Wayland protocol extensions the Linux viewer
speaks. Every file here except this one is the output of `wayland-scanner`
run over the protocol definitions shipped by `wayland-protocols` (and, for
layer shell, `wlr-protocols`), and none of it is written by hand.

SwiftPM cannot run a generator as part of building a C target, so the output
is generated on a machine that has the definitions installed and committed
here. Regenerate with:

    Scripts/regenerate-wayland-protocols.sh

which runs, for each protocol below:

    wayland-scanner client-header <definition>.xml include/<definition>-client-protocol.h
    wayland-scanner private-code  <definition>.xml <definition>-protocol.c

The committed files were generated with wayland-scanner 1.25.0 from
wayland-protocols 1.49:

| Protocol | Definition |
| --- | --- |
| xdg-shell | stable/xdg-shell/xdg-shell.xml |
| xdg-decoration | unstable/xdg-decoration/xdg-decoration-unstable-v1.xml |
| viewporter | stable/viewporter/viewporter.xml |
| fractional-scale | staging/fractional-scale/fractional-scale-v1.xml |
| relative-pointer | unstable/relative-pointer/relative-pointer-unstable-v1.xml |
| pointer-constraints | unstable/pointer-constraints/pointer-constraints-unstable-v1.xml |
| keyboard-shortcuts-inhibit | unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml |
| presentation-time | stable/presentation-time/presentation-time.xml |
| linux-dmabuf | stable/linux-dmabuf/linux-dmabuf-v1.xml |
| wlr-layer-shell | unstable/wlr-layer-shell-unstable-v1.xml, from `wlr-protocols` |

The `wlr-layer-shell` row was generated with wayland-scanner 1.26.0 from the
Fedora 44 package `wlr-protocols-devel` 0^20250816gita741f0a-1.fc44, which
installs the definition at
`/usr/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml`
(`zwlr_layer_shell_v1` version 5). `wayland-protocols` does not carry it: it
is a wlroots protocol that KWin and most other compositors also implement.

`private-code` rather than `public-code`: the interface descriptions are
linked into this build alone and are not exported for another library to bind
against.
