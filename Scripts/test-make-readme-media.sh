#!/bin/sh
# Contract and functional test for the README media generator.
#
# Placeholder pictures stand in for the real renders, one per allowlisted
# name at the real render size, so the generator's layout, encoders and size
# budgets are exercised without rendering either app.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GENERATOR="$ROOT/Scripts/make-readme-media.swift"
WORK="$ROOT/Artifacts/readme-media-test"

fail() {
  printf 'make-readme-media: %s\n' "$1" >&2
  exit 1
}

[ -f "$GENERATOR" ] || fail "Scripts/make-readme-media.swift does not exist"

# The generator may only read the allowlisted renders, and never the two
# families that show this machine's real installed applications.
if grep -nE 'host-launcher|host-workspace-content|viewer-hud' "$GENERATOR" >&2; then
  fail 'the generator must not name host-launcher or host-workspace-content renders'
fi
if grep -nE '"/(private/)?(tmp|var|Users|opt|usr|Volumes)/' "$GENERATOR" >&2; then
  fail 'the generator must not hard-code an absolute path outside this repository'
fi
if grep -niE 'AVFoundation|AVAsset|mp4' "$GENERATOR" >&2; then
  fail 'the generator must not produce video'
fi
grep -F 'docs/media' "$GENERATOR" >/dev/null || fail 'the default output directory must be docs/media'

# Each beat of the walkthrough carries its caption.
while IFS= read -r caption; do
  grep -F -- "$caption" "$GENERATOR" >/dev/null || fail "the generator is missing the caption: $caption"
done <<'CAPTIONS'
In Sensorium Host, click Show pairing code.
Sensorium Host shows a six-digit code.
In Sensorium, click Add a Machine and pick the host.
Type the code from the host: 418 297
You now see and control the host's screen.
The host shows who is connected, with a Stop button.
CAPTIONS

for staged in 'Forecast.swift · tide' 'Executed 12 tests, with 0 failures'; do
  grep -F -- "$staged" "$GENERATOR" >/dev/null || fail "the generator is missing the staged host screen text: $staged"
done
for curve in '0.23, 1, 0.32, 1' '0.77, 0, 0.175, 1'; do
  grep -F -- "$curve" "$GENERATOR" >/dev/null || fail "the generator is missing the easing curve $curve"
done

rm -rf "$WORK"
mkdir -p "$WORK/in" "$WORK/out" "$WORK/out-missing"

# name width height
cat > "$WORK/sizes.txt" <<'SIZES'
viewer-machines-1-empty 920 304
host-window-3-ready-no-machines-paired 720 870
host-window-4-pairing-code-shown 720 1130
viewer-add-1-picker 920 850
viewer-add-2-code 920 534
viewer-add-2b-code-typed-1 920 534
viewer-add-2b-code-typed-2 920 534
viewer-add-2b-code-typed-3 920 534
viewer-add-2b-code-typed-4 920 534
viewer-add-2b-code-typed-5 920 534
viewer-add-2b-code-typed-6 920 534
viewer-shortcuts-1b-pinned 1920 1200
host-screen-badge-1-expanded 604 180
host-screen-presence-prompt-1-short 720 482
host-window-12-last-session-clean-stop 720 1498
SIZES

python3 -I - "$WORK" <<'PY'
import struct, sys, zlib

work = sys.argv[1]

def png(path, width, height, rgb):
    row = b"\x00" + bytes(rgb) * width
    raw = row * height
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))
    with open(path, "wb") as out:
        out.write(b"\x89PNG\r\n\x1a\n")
        out.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        out.write(chunk(b"IDAT", zlib.compress(raw)))
        out.write(chunk(b"IEND", b""))

for index, line in enumerate(open(work + "/sizes.txt")):
    name, width, height = line.split()
    shade = 40 + (index * 37) % 180
    png("%s/in/%s.png" % (work, name), int(width), int(height), (shade, 90, 255 - shade))
PY

if ! swift "$GENERATOR" "$WORK/in" "$WORK/out" > "$WORK/run.log" 2>&1; then
  cat "$WORK/run.log" >&2
  fail 'the generator failed on a complete set of inputs'
fi

for output in pairing.gif pairing-still.png at-the-host.png social-preview.png; do
  [ -s "$WORK/out/$output" ] || fail "missing output $output"
done

size_of() { wc -c < "$1" | tr -d ' '; }
pixels_of() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}'; }

[ "$(ls "$WORK/out" | sort | tr '\n' ' ')" = "at-the-host.png pairing-still.png pairing.gif social-preview.png " ] \
  || fail "the output directory must hold exactly the four media files, found: $(ls "$WORK/out" | tr '\n' ' ')"

[ "$(pixels_of "$WORK/out/social-preview.png")" = "1280x640" ] || fail 'social-preview.png is not 1280x640'
[ "$(sips -g pixelWidth "$WORK/out/at-the-host.png" | awk '/pixelWidth/ {print $2}')" = "2048" ] \
  || fail 'at-the-host.png is not 2048 wide'
[ "$(pixels_of "$WORK/out/pairing-still.png")" = "2048x1152" ] || fail 'pairing-still.png is not 2048x1152'
[ "$(pixels_of "$WORK/out/pairing.gif")" = "1280x720" ] || fail 'pairing.gif is not 1280x720'

[ "$(size_of "$WORK/out/social-preview.png")" -le 1048576 ] || fail 'social-preview.png is over 1 MB'
[ "$(size_of "$WORK/out/pairing-still.png")" -le 1048576 ] || fail 'pairing-still.png is over 1 MB'
[ "$(size_of "$WORK/out/pairing.gif")" -le 5242880 ] || fail 'pairing.gif is over 5 MB'

python3 -I - "$WORK/out/pairing.gif" <<'PY' || fail 'pairing.gif has a single frame or no loop extension'
import sys
data = open(sys.argv[1], "rb").read()
frames = data.count(b"\x21\xf9\x04")
if frames < 2 or b"NETSCAPE2.0" not in data:
    sys.exit(1)
PY

# One missing input stops the run, and nothing is written.
rm "$WORK/in/host-screen-badge-1-expanded.png"
if swift "$GENERATOR" "$WORK/in" "$WORK/out-missing" > "$WORK/missing.log" 2>&1; then
  fail 'the generator succeeded with an allowlisted render missing'
fi
grep -F 'host-screen-badge-1-expanded' "$WORK/missing.log" >/dev/null \
  || fail 'the generator did not name the missing render'

rm -rf "$WORK"
printf 'PASS: README media generator contract\n'
