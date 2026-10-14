#!/bin/sh
# Exercises Scripts/make-dmg-layout.swift on a scratch read-write disk image:
# the Finder window it records, the item positions, the background picture it
# points at, and that the file it writes names nothing of the machine that
# built it. Attaches the image without showing it in Finder and detaches it
# before exiting.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LAYOUT="$ROOT/Scripts/make-dmg-layout.swift"
[ -f "$LAYOUT" ] || { echo "Scripts/make-dmg-layout.swift is missing" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sensorium-dmg-layout-test.XXXXXX")"
MNT="$WORK/mnt"
ATTACHED=""
detach_volume() {
  for attempt in 1 2 3; do
    hdiutil detach "$1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  hdiutil detach -force "$1" >/dev/null 2>&1
}
cleanup() {
  if [ -n "$ATTACHED" ]; then detach_volume "$ATTACHED" || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() { echo "FAIL: $1" >&2; [ -f "$WORK/out" ] && sed 's/^/  | /' "$WORK/out" >&2; exit 1; }

STAGE="$WORK/stage"
mkdir -p "$STAGE/Example.app/Contents" "$STAGE/.background" "$MNT"
ln -s /Applications "$STAGE/Applications"
# Dot entries a release image holds, and one it may hold later.
printf 'icon\n' > "$STAGE/.VolumeIcon.icns"
printf 'later\n' > "$STAGE/.future"
# The writer only needs the picture to exist; a one-pixel TIFF stands in.
python3 -I - "$STAGE/.background/background.tiff" <<'PY'
import struct, sys
entries = [(256, 3, 1), (257, 3, 1), (258, 3, 8), (259, 3, 1), (262, 3, 1), (273, 4, 0), (278, 3, 1), (279, 4, 1)]
data_offset = 8 + 2 + 12 * len(entries) + 4
ifd = struct.pack('>H', len(entries))
for tag, kind, value in entries:
    value = data_offset if tag == 273 else value
    ifd += struct.pack('>HHI', tag, kind, 1) + (struct.pack('>HH', value, 0) if kind == 3 else struct.pack('>I', value))
open(sys.argv[1], 'wb').write(b'MM\0*' + struct.pack('>I', 8) + ifd + b'\0\0\0\0' + b'\x80')
PY

hdiutil create -volname "Layout Test" -srcfolder "$STAGE" -fs HFS+ -format UDRW "$WORK/layout.dmg" >/dev/null ||
  fail "the scratch image could not be created"
hdiutil attach -readwrite -nobrowse -noautoopen -mountpoint "$MNT" "$WORK/layout.dmg" >/dev/null ||
  fail "the scratch image could not be attached"
ATTACHED="$MNT"

cat > "$WORK/layout.json" <<'JSON'
{"windowWidth": 760, "windowHeight": 500, "iconSize": 128, "textSize": 13,
 "appX": 200, "appY": 230, "applicationsX": 560, "applicationsY": 230,
 "backgroundRed": 0.98, "backgroundGreen": 0.98, "backgroundBlue": 0.99}
JSON

# A layout without one of its keys is refused, naming the key.
python3 -I - "$WORK/layout.json" "$WORK/broken.json" <<'PY'
import json, sys
layout = json.load(open(sys.argv[1]))
del layout['applicationsY']
json.dump(layout, open(sys.argv[2], 'w'))
PY
(swift "$LAYOUT" write "$MNT" "Layout Test" Example.app "$WORK/broken.json" > "$WORK/out" 2>&1) &&
  fail "a layout without applicationsY must be refused"
grep -qF "applicationsY" "$WORK/out" || fail "the refusal should name the missing key"
[ ! -e "$MNT/.DS_Store" ] || fail "a refused layout must not leave a .DS_Store"

swift "$LAYOUT" write "$MNT" "Layout Test" Example.app "$WORK/layout.json" > "$WORK/out" 2>&1 ||
  fail "write should succeed"
[ -f "$MNT/.DS_Store" ] || fail "write should create .DS_Store at the volume root"

swift "$LAYOUT" dump "$MNT/.DS_Store" > "$WORK/out" 2>&1 || fail "dump should read the written file"
line() { grep "^$1 $2 " "$WORK/out" || fail "dump should list a $2 record for $1"; }
has() { printf '%s\n' "$1" | grep -qF " $2" || fail "$3"; }

[ "$(line Example.app Iloc)" = "Example.app Iloc 200,230" ] || fail "the app should sit at 200,230"
[ "$(line Applications Iloc)" = "Applications Iloc 560,230" ] || fail "Applications should sit at 560,230"
[ "$(line . vSrn)" = ". vSrn 1" ] || fail "the view version record should be 1"

ICVP="$(line . icvp)"
has "$ICVP" "backgroundType=2" "the background should be a picture"
has "$ICVP" "backgroundImageAlias=/Volumes/Layout Test/.background/background.tiff" "the background alias should name this volume and a path inside it"
has "$ICVP" "iconSize=128.0" "icons should be 128 points"
has "$ICVP" "textSize=13.0" "labels should be 13 points"
has "$ICVP" "arrangeBy=none" "icons should keep their positions"
has "$ICVP" "backgroundColorBlue=0.99" "the background colour should come from the layout"

BWSP="$(line . bwsp)"
has "$BWSP" "WindowBounds={{160, 160}, {760, 528}}" "the window should be the layout size plus the title bar"
for key in ShowToolbar ShowSidebar ContainerShowSidebar ShowStatusBar ShowTabView; do
  has "$BWSP" "$key=false" "$key should be off"
done

# Finder shows dot entries when it is set to show hidden files. Each one on
# the volume, other than .DS_Store, sits wholly beyond the window's right
# edge, apart from the others.
DOTS="$(ls -A "$MNT" | grep '^\.' | grep -vx '\.DS_Store')"
[ "$(printf '%s\n' "$DOTS" | wc -l | tr -d ' ')" = 3 ] || fail "the scratch volume should hold three dot entries besides .DS_Store"
YS=""
while IFS= read -r item; do
  LOC="$(awk -v name="$item" '$1 == name && $2 == "Iloc" { print $3 }' "$WORK/out")"
  [ -n "$LOC" ] || fail "$item should have a position"
  [ "$(( ${LOC%,*} - 128 / 2 ))" -ge 760 ] || fail "$item should sit beyond the window's right edge, not at $LOC"
  YS="$YS ${LOC#*,}"
done <<EOF
$DOTS
EOF
[ -z "$(printf '%s\n' $YS | sort | uniq -d)" ] || fail "dot entries should not share a position"

# Records are sorted by name, ignoring case, so Finder can search them.
[ "$(cut -d' ' -f1-2 "$WORK/out" | tr '\n' ' ')" = ". bwsp . icvp . vSrn .background Iloc .future Iloc .VolumeIcon.icns Iloc Applications Iloc Example.app Iloc " ] ||
  fail "records should be sorted by name, then by kind"

# Nothing in the file may name the machine that built it, in any encoding a
# Finder record uses.
python3 -I - "$MNT/.DS_Store" "$WORK" "$HOME" "/Users/" "/private/" ".dmg" "Macintosh HD" > "$WORK/out" <<'PY' || fail ".DS_Store names a path or name of this machine"
import sys
data = open(sys.argv[1], 'rb').read()
found = [s for s in sys.argv[2:] if any(s.encode(e) in data for e in ('utf-8', 'utf-16-be', 'utf-16-le'))]
print('\n'.join(found))
sys.exit(1 if found else 0)
PY

printf 'PASS: disk image window layout, positions, background alias, no machine paths\n'
