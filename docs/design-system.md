# Sensorium design system

The tokens and rules Sensorium's host interface draws on, applied by `Sources/SensoriumHost/CanvasDesignSystem.swift`. Anything drawn on the session canvas takes its colours, metrics, and faces from here, not from AppKit's semantic colours, which follow the host machine's own palette.

## Appearance
Each macOS app has an appearance setting with three choices. The setting is kept per app, so the host and the viewer each keep their own.

| choice | result                                             |
| ------ | -------------------------------------------------- |
| System | follows the machine. This is the default.          |
| Light  | always draws the light values.                     |
| Dark   | always draws the dark values.                      |

A missing or unreadable stored value counts as System. Dark is the original look of the product. Light keeps the same feel: warm off-white surfaces, near-black ink, borders instead of shadows, sharp radii.

## Tokens
Every colour has a dark value and a light value. The dark values are the original ones, and the light values do not change them.

### Workspace surfaces
| token  | dark      | light     | use                 |
| ------ | --------- | --------- | ------------------- |
| bg     | `#0A0A0C` | `#F5F3EE` | deepest surface     |
| bg-2   | `#121216` | `#FBFAF7` | panel               |
| bg-3   | `#1A1A20` | `#EAE7E0` | elevated / hover    |
| bg-4   | `#24242C` | `#E0DDD5` | input fill          |

### Chrome
The shell's own "housing", kept distinct from the workspace surfaces.
| token             | dark      | light     |
| ----------------- | --------- | --------- |
| chrome-bg         | `#07070A` | `#ECE9E2` |
| chrome-bg-2       | `#0E0E14` | `#F3F1EB` |
| chrome-bg-hover   | `#14141A` | `#E3E0D8` |
| chrome-border     | `#18181E` | `#D6D2C9` |
| chrome-border-2   | `#1F1F26` | `#CCC8BE` |
| chrome-ink        | `#E8E5DE` | `#1E1D1A` |
| chrome-ink-2      | `#C8C5BD` | `#46433E` |
| chrome-muted      | `#8A8A92` | `#5F5E64` |
| chrome-muted-2    | `#5A5A63` | `#777680` |

### Lines
| token   | dark      | light     |
| ------- | --------- | --------- |
| line    | `#24242C` | `#DAD6CD` |
| line-2  | `#34343F` | `#C6C2B8` |
| line-hi | `#43434F` | `#AAA69B` |

### Text
| token   | dark      | light     |
| ------- | --------- | --------- |
| ink     | `#F2EFEA` | `#1A1917` |
| ink-2   | `#C8C5BD` | `#433F3A` |
| muted   | `#8C8C94` | `#626068` |
| muted-2 | `#5A5A63` | `#7C7A82` |
| muted-3 | `#3A3A44` | `#B3B0A8` |

### Accent
Use sparingly, for selection, focus, and active states only.

The light accent is already the deep variant, so it reads as text on a light surface. The translucent tokens use the accent of their own appearance.
| token         | dark                     | light                    |
| ------------- | ------------------------ | ------------------------ |
| accent        | `#7C70F5`                | `#5B4FDB`                |
| accent-hi     | `#9088F8`                | `#6A5EEA`                |
| accent-deep   | `#5A4FC0`                | `#4338A8`                |
| accent-soft   | `rgba(124,112,245,0.10)` | `rgba(91,79,219,0.10)`   |
| accent-bd     | `rgba(124,112,245,0.30)` | `rgba(91,79,219,0.30)`   |
| selection     | `rgba(124,112,245,0.32)` | `rgba(91,79,219,0.32)`   |
| accent-2      | `#F0A8D0`                | `#B8437F`                |
| accent-2-hi   | `#F5BFE0`                | `#C0508C`                |
| accent-2-deep | `#C87AAA`                | `#9A3366`                |
| accent-2-soft | `rgba(240,168,208,0.10)` | `rgba(184,67,127,0.10)`  |
| accent-2-bd   | `rgba(240,168,208,0.30)` | `rgba(184,67,127,0.30)`  |

Accent-2 comes from the Blutarche Studio design system.

### Status
| token | dark      | light     |
| ----- | --------- | --------- |
| ok    | `#6FBE83` | `#267340` |
| bad   | `#E26F5C` | `#B93A26` |
| info  | `#8EE0E8` | `#157383` |
| warn  | `#E0B85D` | `#8F6000` |

The viewer's scrim stays black at 0.66 opacity in both appearances.

### Contrast in light
The tests compute WCAG contrast on every light surface a token is drawn on.

| text                                              | minimum |
| ------------------------------------------------- | ------- |
| ink, ink-2, chrome-ink, chrome-ink-2, accent-deep | 4.5:1   |
| muted, muted-2, chrome-muted, chrome-muted-2      | 3:1     |
| accent, accent-hi, accent-2, status colours       | 3:1     |
| a chrome-bg title on an accent or status fill     | 4.5:1   |

### Metrics
- Radii, kept sharp: `0` / `2` / `4` / `6`px. Nothing goes past 6.
- Spacing, on a 4px grid: `4 8 12 16 20 24 32 40 48 64`.

### Type
- Inter for primary UI.
- Space Grotesk for the wordmark only.
- JetBrains Mono for labels, data, and code.

Space Grotesk carries identity only. Body text stays on Inter, which reads better at small sizes once H.264 encoding and downscaling would blur a display grotesque's letterforms.

Sizes: `11 / 12 / 14 / 16 / 18 / 20 / 24`px.
Weights: `300` light · `400` regular · `500` medium · `600` semibold · `700` bold.
Tracking: tight `-0.03em` · snug `-0.015em` · normal `0` · wide `0.06em` · wider `0.12em` · widest `0.22em`.

### Motion
`instant` 60ms · `fast` 120ms · `base` 200ms · `slow` 300ms.

## Binding rules
- **Two appearances, one system.** Light and dark share every metric, face, and rule below. Only the colour values differ.
- **No drop shadows.** Borders and background colour separate cards from each other, not elevation.
- **Functional first.** Every element earns its space. No decoration.
- **Dense but not cluttered.** More information per screen than a consumer app, with clear hierarchy.
- **Not bubbly.** Rounded-everything UI is an anti-pattern here. Radii stay sharp.
- **No wasted whitespace.** Also an anti-pattern here.
- **Understated branding.** The wordmark is the product name, in the alternate face, nothing more.
- **Uppercase mono for eyebrow and label text**, 12px, widest tracking (0.22em), muted.
- Monospace is for raw data, such as labels, keyboard hints, code, and telemetry, not a list of application names.
- **Empty states carry two lines.** A heading says what is empty. Subtext says what to do.

## Mapping onto AppKit
This system was written for the web. Sensorium's host UI is native AppKit, drawn on the session canvas, so the tokens map as follows.
| system concept        | AppKit                                                                                       |
| --------------------- | -------------------------------------------------------------------------------------------- |
| `#RRGGBB`             | `DesignColor.nsColor`, a dynamic `NSColor` that picks the dark or light value from the drawing appearance. Never a semantic colour such as `.controlBackgroundColor`. Those follow the host's palette. |
| `rgba(r,g,b,a)`       | the same colour with the alpha carried through. AppKit composites the same way CSS does. |
| appearance setting    | `AppearancePreference.nsAppearance`: `nil` for System, `NSAppearance(named: .aqua)` for Light, `NSAppearance(named: .darkAqua)` for Dark. Assigned to the app; windows inherit it. |
| layer colours         | `DesignColor.cgColor` resolves once, in the drawing appearance at that moment. Layers retain their source NSColor through AppearanceLayerColors, which resolves fills, borders, alpha variants and gradients when appearance changes and when a window first updates. |
| `border-radius`       | `view.wantsLayer = true` and `view.layer?.cornerRadius`. |
| `border: 1px solid c` | `layer?.borderWidth = 1` and `layer?.borderColor = c.cgColor`, or `NSBezierPath(roundedRect:)` inset by 0.5pt on a hand-drawn row. |
| no shadows            | never set `NSShadow`, `layer?.shadowOpacity`, or `NSVisualEffectView`. |
| `font-family`         | `NSFont(descriptor:size:)` with `.family`, guarded by a membership check against `NSFontManager.shared.availableFontFamilies`. |
| `font-weight`         | `NSFontDescriptor.TraitKey.weight` with the matching `NSFont.Weight`. On the fallback face, `NSFont.systemFont(ofSize:weight:)`. |
| `letter-spacing` (em) | `NSAttributedString.Key.kern`, in points: `tracking × size`. |
| motion durations      | not used. The host UI has no animation. The canvas is a video stream. |

The viewer's `ViewerColor` carries the same pairs without AppKit, so the GTK viewer can read them. `resolved(for:)` and `hexString(for:)` take a `ResolvedAppearance`.

### Fonts, and the fallback
Inter, Space Grotesk, and JetBrains Mono are Google fonts, installed by the user in `~/Library/Fonts`. This repository does not ship or install them. `CanvasDesign` checks each family against `NSFontManager.shared.availableFontFamilies` before building a descriptor, so a host without them falls back, at the same size and weight:
- primary and alternate -> `NSFont.systemFont(ofSize:weight:)` (SF Pro).
- mono -> `NSFont.monospacedSystemFont(ofSize:weight:)` (SF Mono).
