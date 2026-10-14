#!/bin/sh
# Contract and functional test for the disk image background generator.
#
# Renders each role's background twice into scratch folders and checks what
# the release script relies on: a 1x and a 2x picture that tiffutil accepts as
# one HiDPI pair, the window layout Finder is told to use, byte-for-byte
# reproducibility, one layout and two different pictures for the two roles,
# and that every place Finder draws an icon or its black label stays a light,
# clean panel.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GENERATOR="$ROOT/Scripts/make-dmg-background.swift"

fail() {
  printf 'make-dmg-background: %s\n' "$1" >&2
  exit 1
}

[ -f "$GENERATOR" ] || fail "Scripts/make-dmg-background.swift does not exist"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sensorium-dmg-background-test.XXXXXX")"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if swift "$GENERATOR" desktop "$WORK/unknown" > "$WORK/unknown.log" 2>&1; then
  fail "an unknown role should be refused"
fi
[ ! -e "$WORK/unknown" ] || fail "an unknown role should write nothing"
if swift "$GENERATOR" "$WORK/no-role" > "$WORK/no-role.log" 2>&1; then
  fail "a missing role should be refused"
fi

pixels_of() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}'; }
dpi_of() { sips -g dpiWidth -g dpiHeight "$1" | awk '/dpiWidth/ {w=$2} /dpiHeight/ {h=$2} END {printf "%gx%g\n", w, h}'; }

for role in viewer host; do
  for run in first second; do
    if ! swift "$GENERATOR" "$role" "$WORK/$role-$run" > "$WORK/$role-$run.log" 2>&1; then
      cat "$WORK/$role-$run.log" >&2
      fail "the generator failed on the $run $role run"
    fi
  done
  OUT="$WORK/$role-first"

  [ "$(ls "$OUT" | LC_ALL=C sort | tr '\n' ' ')" = "background.png background@2x.png layout.json " ] \
    || fail "the $role output directory must hold exactly the three files, found: $(ls "$OUT" | tr '\n' ' ')"

  for output in background.png background@2x.png layout.json; do
    [ -s "$OUT/$output" ] || fail "$role $output is empty"
    cmp -s "$OUT/$output" "$WORK/$role-second/$output" || fail "$role $output differs between two runs"
  done

  [ "$(pixels_of "$OUT/background.png")" = "760x500" ] || fail "$role background.png is not 760x500"
  [ "$(pixels_of "$OUT/background@2x.png")" = "1520x1000" ] || fail "$role background@2x.png is not 1520x1000"
  [ "$(dpi_of "$OUT/background.png")" = "72x72" ] || fail "$role background.png is not 72 dpi"
  [ "$(dpi_of "$OUT/background@2x.png")" = "144x144" ] || fail "$role background@2x.png is not 144 dpi"

  # Finder takes the pair as one picture only when tiffutil can join them.
  if ! tiffutil -cathidpicheck "$OUT/background.png" "$OUT/background@2x.png" \
    -out "$WORK/$role.tiff" > "$WORK/$role-tiffutil.log" 2>&1; then
    cat "$WORK/$role-tiffutil.log" >&2
    fail "tiffutil -cathidpicheck rejected the $role 1x and 2x pair"
  fi
  tiffutil -info "$WORK/$role.tiff" > "$WORK/$role-tiff-info.log" 2>&1
  [ "$(grep -c '^Directory at' "$WORK/$role-tiff-info.log")" = "2" ] \
    || { cat "$WORK/$role-tiff-info.log" >&2; fail "the $role background.tiff does not hold exactly two images"; }
done

# Both disk images share one window layout and differ only in their picture.
cmp -s "$WORK/viewer-first/layout.json" "$WORK/host-first/layout.json" \
  || fail "layout.json differs between the viewer and the host"
for output in background.png background@2x.png; do
  if cmp -s "$WORK/viewer-first/$output" "$WORK/host-first/$output"; then
    fail "the viewer and the host draw the same $output"
  fi
done

LAYOUT="$WORK/viewer-first/layout.json"
# plutil -lint rejects every JSON file; converting it is how plutil parses one.
plutil -convert xml1 -o /dev/null "$LAYOUT" || fail 'layout.json does not parse'
while read -r key expected; do
  [ "$(plutil -extract "$key" raw -o - "$LAYOUT")" = "$expected" ] \
    || fail "layout.json $key is not $expected"
done <<'LAYOUT'
windowWidth 760
windowHeight 500
iconSize 128
textSize 13
appX 230
appY 108
applicationsX 530
applicationsY 288
LAYOUT

# The release script reads these keys and nothing else; the colour Finder
# paints outside the picture has to be the picture's own base colour.
BASE="$(python3 -I - "$LAYOUT" <<'PY'
import json, sys

layout = json.load(open(sys.argv[1]))
keys = {
    "windowWidth", "windowHeight", "iconSize", "textSize",
    "appX", "appY", "applicationsX", "applicationsY",
    "backgroundRed", "backgroundGreen", "backgroundBlue",
}
if set(layout) != keys:
    sys.exit("layout.json keys differ: %s" % sorted(set(layout) ^ keys))
for key, value in layout.items():
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        sys.exit("layout.json %s is not a number" % key)
channels = [layout[k] for k in ("backgroundRed", "backgroundGreen", "backgroundBlue")]
if any(not 0 <= c <= 1 for c in channels):
    sys.exit("layout.json background colour is outside 0-1")
print(" ".join(str(round(c * 255)) for c in channels))
PY
)" || fail 'layout.json is not the flat object of numbers the release script reads'
[ "$BASE" = "10 10 12" ] || fail "layout.json background colour is $BASE, not #0A0A0C"

# Finder draws icon labels in black over a background picture, even in dark
# mode, so the picture is dark except for two light panels that carry the
# icons and their labels. Rectangles are in Finder points, origin top-left,
# around the icon centres layout.json gives: 80 either side, 64 above and 104
# below holds an icon and its label. All of that is light, meaning a luma of
# at least 0.85 from the sRGB-encoded channels with Rec. 709 weights, against
# which black text has a contrast ratio above 14:1. It is a clean panel as
# well, with no stroke, dot or grain: no channel steps by more than one level
# between neighbouring pixels. The bottom strip, which a taller title bar
# than expected would crop and a shorter one would extend with the layout's
# background colour, is exactly that colour.
#
# Each machine is one drawing in both pictures. The portable stands in front
# in the viewer's picture and at the back in the host's; the desk display the
# other way round. Moved by the distance between the icon centres, each
# machine's body must match pixel for pixel. Its body is its housing, 340 by
# 220 points with 14 point corners, 170 left of and 90 above the icon centre
# on its panel, and its base below: a 40 by 24 neck over a 136 by 8 foot for
# the display, a 240 by 4 hinge over a 384 by 12 deck for the portable. The
# outermost 2 points blend with the room and are not compared, nor are the
# icons, the arrow, and the corner of the back machine that the front one and
# its moat of room cover.
for picture in background.png:1 background@2x.png:2; do
  python3 -I - "$WORK/viewer-first/${picture%:*}" "$WORK/host-first/${picture%:*}" "${picture#*:}" "$LAYOUT" <<'PY' \
    || fail "${picture%:*} breaks the picture's rules"
import json, struct, sys, zlib

scale = int(sys.argv[3])
layout = json.load(open(sys.argv[4]))
base = (10, 10, 12)

def decode(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit("%s is not a PNG" % path)
    position, idat = 8, b""
    while position < len(data):
        length, tag = struct.unpack(">I4s", data[position:position + 8])
        body = data[position + 8:position + 8 + length]
        if tag == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat += body
        position += 12 + length
    if depth != 8 or colour not in (2, 6) or interlace != 0:
        sys.exit("unexpected PNG format: depth %d, colour type %d, interlace %d" % (depth, colour, interlace))
    channels = 3 if colour == 2 else 4
    stride = width * channels
    raw = zlib.decompress(idat)
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = previous[i]
            if kind == 1:
                line[i] = (line[i] + left) & 0xFF
            elif kind == 2:
                line[i] = (line[i] + up) & 0xFF
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif kind == 4:
                corner = previous[i - channels] if i >= channels else 0
                guess = left + up - corner
                pa, pb, pc = abs(guess - left), abs(guess - up), abs(guess - corner)
                line[i] = (line[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 0xFF
        rows.append(line)
        previous = line
    if channels == 4 and any(line[i] != 255 for line in rows for i in range(3, stride, 4)):
        sys.exit("%s is not opaque" % path)
    rgb = [bytes(line[i] for i in range(stride) if i % channels < 3) if channels == 4 else bytes(line)
           for line in rows]
    return width, height, rgb

def luma(p):
    return (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) / 255

def pixels(rect):
    x0, y0, x1, y1 = rect
    for y in range(y0 * scale, y1 * scale):
        for x in range(x0 * scale, x1 * scale):
            yield x, y

pictures = {}
for role, path in (("viewer", sys.argv[1]), ("host", sys.argv[2])):
    width, height, rows = decode(path)
    pictures[role] = rows

    def pixel(x, y):
        return tuple(rows[y][x * 3:x * 3 + 3])

    def light(name, rect):
        dim = [(x, y) for x, y in pixels(rect) if luma(pixel(x, y)) < 0.85]
        if dim:
            x, y = dim[0]
            sys.exit("%s: %d pixels under the %s have a luma below 0.85, first %s at (%d, %d) px"
                     % (role, len(dim), name, pixel(x, y), x, y))

    def clean(name, rect):
        x0, y0, x1, y1 = (v * scale for v in rect)
        for x, y in pixels(rect):
            here = pixel(x, y)
            for nx, ny in ((x + 1, y), (x, y + 1)):
                if nx < x1 and ny < y1:
                    there = pixel(nx, ny)
                    if max(abs(a - b) for a, b in zip(here, there)) > 1:
                        sys.exit("%s: the %s is not a clean panel: %s at (%d, %d) px next to %s at (%d, %d) px"
                                 % (role, name, here, x, y, there, nx, ny))

    for name, prefix in {"app": "app", "Applications": "applications"}.items():
        cx, cy = layout[prefix + "X"], layout[prefix + "Y"]
        light("%s icon and label" % name, (cx - 80, cy - 64, cx + 80, cy + 104))
        clean("%s icon and label" % name, (cx - 80, cy - 64, cx + 80, cy + 104))

    strip = [(x, y) for x, y in pixels((0, 500 - 32, 760, 500)) if pixel(x, y) != base]
    if strip:
        x, y = strip[0]
        sys.exit("%s: %d pixels in the bottom strip are not %s, first %s at (%d, %d) px"
                 % (role, len(strip), base, pixel(x, y), x, y))

    # The room around the two machines is dark and carries a texture: grain
    # and a dot grid, not one flat colour.
    room = (0, 320, 240, 440)
    bright = [(x, y) for x, y in pixels(room) if luma(pixel(x, y)) > 0.2]
    if bright:
        x, y = bright[0]
        sys.exit("%s: the room left of the near machine is not dark: %s at (%d, %d) px"
                 % (role, pixel(x, y), x, y))
    if len({pixel(x, y) for x, y in pixels(room)}) < 4:
        sys.exit("%s: the room left of the near machine is one flat colour" % role)

app = (layout["appX"], layout["appY"])
applications = (layout["applicationsX"], layout["applicationsY"])
dx, dy = applications[0] - app[0], applications[1] - app[1]

def in_rounded(px, py, rect, corner):
    x0, y0, x1, y1 = rect
    if not (x0 <= px <= x1 and y0 <= py <= y1):
        return False
    ex = max(x0 + corner - px, px - (x1 - corner), 0)
    ey = max(y0 + corner - py, py - (y1 - corner), 0)
    return ex * ex + ey * ey <= corner * corner

def shapes(form, centre):
    cx, cy = centre
    top, bottom = cy - 90, cy + 130
    parts = [((cx - 170, top, cx + 170, bottom), 14)]
    if form == "desk":
        parts += [((cx - 20, bottom, cx + 20, bottom + 24), 0),
                  ((cx - 68, bottom + 24, cx + 68, bottom + 32), 4)]
    else:
        parts += [((cx - 120, bottom, cx + 120, bottom + 4), 0),
                  ((cx - 192, bottom + 4, cx + 192, bottom + 16), 5)]
    return parts

def body(px, py, parts):
    """Whether the square 2 points either way of a point lies on the machine."""
    return all(any(in_rounded(px + ox, py + oy, rect, corner) for rect, corner in parts)
               for ox in (-2, 0, 2) for oy in (-2, 0, 2))

def icon(px, py, centre):
    return centre[0] - 80 <= px < centre[0] + 80 and centre[1] - 64 <= py < centre[1] + 104

arrow = (app[0] + 80, app[1] + 80, applications[0] - 110, applications[1] - 20)
front_cover = (applications[0] - 178, applications[1] - 98, applications[0] + 178, applications[1] + 138)

def inside(px, py, rect):
    return rect[0] <= px < rect[2] and rect[1] <= py < rect[3]

# The back machine sits on the app's panel, the front one on Applications'.
for form, back, front in (("desk", "viewer", "host"), ("portable", "host", "viewer")):
    behind, ahead = pictures[back], pictures[front]
    parts = shapes(form, app)
    compared = 0
    for y in range(int((app[1] - 90) * scale), int((app[1] + 130 + 32) * scale)):
        for x in range(int((app[0] - 192) * scale), int((app[0] + 192) * scale)):
            px, py = (x + 0.5) / scale, (y + 0.5) / scale
            if (not body(px, py, parts) or icon(px, py, app) or inside(px, py, arrow)
                    or inside(px, py, front_cover) or inside(px + dx, py + dy, arrow)):
                continue
            fx, fy = x + dx * scale, y + dy * scale
            here = behind[y][x * 3:x * 3 + 3]
            there = ahead[fy][fx * 3:fx * 3 + 3]
            if here != there:
                sys.exit("the %s at the back of the %s picture differs from the one in front of the %s "
                         "picture: %s at (%d, %d) px against %s at (%d, %d) px"
                         % (form, back, front, tuple(here), x, y, tuple(there), fx, fy))
            compared += 1
    if compared < 30000 * scale * scale:
        sys.exit("only %d pixels of the %s were compared" % (compared, form))
PY
done

printf 'PASS: disk image background generator contract\n'
