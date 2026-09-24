# Viewer icons, hicolor layout

The PNGs under `hicolor/` are generated, never edited. They are the viewer
mark from `Scripts/make-app-icons.swift`, drawn at each size rather than
downsampled from one, and they are committed because the renderer is
CoreGraphics and only runs on macOS.

Regenerate them, from the repository root, on macOS:

```sh
swift Scripts/make-app-icons.swift --linux Packaging/linux/icons
```

The drawing is deterministic, so a regeneration that changes a byte means the
mark changed. The macOS CI job regenerates them into a temporary directory and
compares, which is what keeps these files honest.
