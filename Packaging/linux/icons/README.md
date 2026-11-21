# Sensorium app icons, hicolor layout

`Scripts/make-app-icons.swift` renders the viewer and host marks under
`hicolor/` at each icon size. The PNGs are checked in so Linux can package
them without running the CoreGraphics renderer on macOS.

Regenerate them, from the repository root, on macOS:

```sh
swift Scripts/make-app-icons.swift --linux Packaging/linux/icons
```

The drawing is deterministic, so a regeneration that changes a byte means the
mark changed. The macOS CI job regenerates them into a temporary directory and
compares, which is what keeps these files honest.
