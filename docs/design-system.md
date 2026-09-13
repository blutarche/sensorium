# Sensorium design system

The tokens and rules Sensorium's host interface draws on, applied by `Sources/SensoriumHost/CanvasDesignSystem.swift`. Anything drawn on the session canvas takes its colours, metrics, and faces from here, not from AppKit's semantic colours, which follow the host machine's own appearance.

## Tokens
Dark theme only. This product has no light theme, so light values are not recorded here.

### Workspace surfaces
| token  | value     | use                 |
| ------ | --------- | ------------------- |
| bg     | `#0A0A0C` | deepest surface     |
| bg-2   | `#121216` | panel               |
| bg-3   | `#1A1A20` | elevated / hover    |
| bg-4   | `#24242C` | input fill          |

### Chrome
The shell's own "housing", kept distinct from the workspace surfaces.
| token             | value     |
| ----------------- | --------- |
| chrome-bg         | `#07070A` |
| chrome-bg-2       | `#0E0E14` |
| chrome-bg-hover   | `#14141A` |
| chrome-border     | `#18181E` |
| chrome-border-2   | `#1F1F26` |
| chrome-ink        | `#E8E5DE` |
| chrome-ink-2      | `#C8C5BD` |
| chrome-muted      | `#8A8A92` |
| chrome-muted-2    | `#5A5A63` |

### Lines
| token   | value     |
| ------- | --------- |
| line    | `#24242C` |
| line-2  | `#34343F` |
| line-hi | `#43434F` |

### Text
| token   | value     |
| ------- | --------- |
| ink     | `#F2EFEA` |
| ink-2   | `#C8C5BD` |
| muted   | `#8C8C94` |
| muted-2 | `#5A5A63` |
| muted-3 | `#3A3A44` |

### Accent
Use sparingly, for selection, focus, and active states only.
| token       | value                      |
| ----------- | -------------------------- |
| accent              | `#7C70F5`                |
| accent-hi           | `#9088F8`                |
| accent-deep         | `#5A4FC0`                |
| accent-soft         | `rgba(124,112,245,0.10)` |
| accent-bd           | `rgba(124,112,245,0.30)` |
| selection           | `rgba(124,112,245,0.32)` |
| accent-2            | `#F0A8D0`                |
| accent-2-hi         | `#F5BFE0`                |
| accent-2-deep       | `#C87AAA`                |
| accent-2-soft       | `rgba(240,168,208,0.10)` |
| accent-2-bd         | `rgba(240,168,208,0.30)` |

Accent-2 comes from the Blutarche Studio design system.

### Status
| token | value     |
| ----- | --------- |
| ok    | `#6FBE83` |
| bad   | `#E26F5C` |
| info  | `#8EE0E8` |
| warn  | `#E0B85D` |

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
- **Dark mode is primary.** This product has no light mode.
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
| `#RRGGBB`             | `NSColor(srgbRed:green:blue:alpha:)`. Never a semantic colour such as `.controlBackgroundColor`. Those follow the host's appearance. |
| `rgba(r,g,b,a)`       | the same initialiser with the alpha carried through. AppKit composites the same way CSS does. |
| dark theme            | `window.appearance = NSAppearance(named: .darkAqua)`. |
| `border-radius`       | `view.wantsLayer = true` and `view.layer?.cornerRadius`. |
| `border: 1px solid c` | `layer?.borderWidth = 1` and `layer?.borderColor = c.cgColor`, or `NSBezierPath(roundedRect:)` inset by 0.5pt on a hand-drawn row. |
| no shadows            | never set `NSShadow`, `layer?.shadowOpacity`, or `NSVisualEffectView`. |
| `font-family`         | `NSFont(descriptor:size:)` with `.family`, guarded by a membership check against `NSFontManager.shared.availableFontFamilies`. |
| `font-weight`         | `NSFontDescriptor.TraitKey.weight` with the matching `NSFont.Weight`. On the fallback face, `NSFont.systemFont(ofSize:weight:)`. |
| `letter-spacing` (em) | `NSAttributedString.Key.kern`, in points: `tracking × size`. |
| motion durations      | not used. The host UI has no animation. The canvas is a video stream. |

### Fonts, and the fallback
Inter, Space Grotesk, and JetBrains Mono are Google fonts, installed by the user in `~/Library/Fonts`. This repository does not ship or install them. `CanvasDesign` checks each family against `NSFontManager.shared.availableFontFamilies` before building a descriptor, so a host without them falls back, at the same size and weight:
- primary and alternate -> `NSFont.systemFont(ofSize:weight:)` (SF Pro).
- mono -> `NSFont.monospacedSystemFont(ofSize:weight:)` (SF Mono).
