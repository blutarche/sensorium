#!/usr/bin/env bash
# Measures streaming latency between a stand-in host on this macOS machine and
# a Linux viewer reached over SSH, with the viewer's synthetic pointer moving
# and resting on a schedule.
#
# The stand-in (`SensoriumBenchHost`) streams synthetic frames through the real
# host media pipeline and listens on this machine's tailnet address. The
# viewer (`SensoriumViewerProbe view`) runs inside a nested virtual KWin on the
# Linux machine, so nothing it does touches that machine's desktop. Neither
# side is paired to anything real: the stand-in keeps its keys in the output
# directory, and the probe keeps its configuration in a scratch directory under
# the remote directory.
#
# Usage:
#   Scripts/benchmark-session.sh --viewer <ssh-destination> [options]
#
#   --viewer DEST     SSH destination of the Linux viewer machine (required)
#   --remote-dir DIR  working directory on the viewer, relative to its home
#                     (default sensorium-bench). Holds the synced tree, the
#                     probe's scratch configuration and each run's files.
#   --port N          port the stand-in listens on (default 7790; 7777 is the
#                     host app's and is refused)
#   --runs N          how many runs to make (default 1)
#   --plan SPEC       pointer plan, for example move:20,still:40,move:20
#                     (default)
#   --seconds N       how long each viewer session runs (default 85)
#   --width N         virtual output width in pixels (default 2560)
#   --height N        virtual output height in pixels (default 1440)
#   --scale F         virtual output scale (default 1.0)
#   --ab              each run makes two sessions, one with the viewer's
#                     release-on-interaction behaviour and one without it
#   --canvas WxH      the stand-in draws and encodes a fixed picture of W by H
#                     pixels (each side even, at most 4096) instead of one that
#                     follows the viewer's window, and writes a packet log. A
#                     picture well above 1920x1080 makes the host encode a
#                     moving picture smaller than a settled one. Each run then
#                     ends with a table of what happened at every change
#                     between the two (Scripts/summarize-motion-switches.py).
#                     Use a plan of several short stretches, for example
#                     --canvas 3008x1692 --seconds 40 \
#                     --plan move:2,still:2,move:2,still:2,move:2,still:2,move:2,still:2,move:2,still:2,move:2,still:2,move:2,still:2
#   --probe-binary P  run the SensoriumViewerProbe at P on the viewer (an
#                     absolute path there, or one relative to the synced tree)
#                     and build no probe there
#   --out DIR         where raw files are kept (default a new directory under
#                     $TMPDIR)
#
# Prerequisites: on this machine a Swift toolchain, rsync, python3 and
# Tailscale; on the viewer an SSH-reachable Linux machine with a Swift
# toolchain, KWin, spectacle and a GPU.
set -u

viewer=""
remote_dir="sensorium-bench"
port=7790
runs=1
plan="move:20,still:40,move:20"
seconds=85
width=2560
height=1440
scale="1.0"
ab=0
canvas=""
probe_binary=""
out=""

die() {
    printf 'benchmark-session: %s\n' "$*" >&2
    exit 2
}

usage_error() {
    die "$* (see the usage at the top of $0)"
}

is_number() { [[ $1 =~ ^[0-9]+$ ]]; }

while [ $# -gt 0 ]; do
    case "$1" in
        --viewer|--remote-dir|--port|--runs|--plan|--seconds|--width|--height|--scale|--canvas|--probe-binary|--out)
            [ $# -ge 2 ] || usage_error "$1 needs a value"
            case "$1" in
                --viewer) viewer=$2 ;;
                --remote-dir) remote_dir=$2 ;;
                --port) port=$2 ;;
                --runs) runs=$2 ;;
                --plan) plan=$2 ;;
                --seconds) seconds=$2 ;;
                --width) width=$2 ;;
                --height) height=$2 ;;
                --scale) scale=$2 ;;
                --canvas) canvas=$2 ;;
                --probe-binary) probe_binary=$2 ;;
                --out) out=$2 ;;
            esac
            shift 2
            ;;
        --ab) ab=1; shift ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) usage_error "unknown option $1" ;;
    esac
done

[ -n "$viewer" ] || usage_error "--viewer is required"
[[ $viewer =~ ^[A-Za-z0-9_][A-Za-z0-9._@-]*$ ]] || usage_error "--viewer must be an SSH destination such as user@machine"
[[ $remote_dir =~ ^/?[A-Za-z0-9_][A-Za-z0-9._/-]*$ && $remote_dir != *..* ]] || usage_error "--remote-dir may hold only letters, digits, . _ - and /"
is_number "$port" && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || usage_error "--port must be a number from 1 to 65535"
[ "$port" -ne 7777 ] || usage_error "port 7777 belongs to the host app; choose another"
is_number "$runs" && [ "$runs" -ge 1 ] || usage_error "--runs must be a whole number above zero"
is_number "$seconds" && [ "$seconds" -ge 1 ] || usage_error "--seconds must be a whole number above zero"
is_number "$width" && [ "$width" -ge 1 ] || usage_error "--width must be a whole number above zero"
is_number "$height" && [ "$height" -ge 1 ] || usage_error "--height must be a whole number above zero"
[[ $scale =~ ^[0-9]+(\.[0-9]+)?$ ]] || usage_error "--scale must be a number such as 1.0"
phase='(move|still):[0-9]+(\.[0-9]+)?'
[[ $plan =~ ^$phase(,$phase)*$ ]] || usage_error "--plan must look like move:20,still:40,move:20"
[ -z "$canvas" ] || [[ $canvas =~ ^[0-9]+x[0-9]+$ ]] || usage_error "--canvas must look like 3008x1692"
[ -z "$probe_binary" ] || [[ $probe_binary =~ ^/?[A-Za-z0-9_][A-Za-z0-9._/-]*$ && $probe_binary != *..* ]] || usage_error "--probe-binary may hold only letters, digits, . _ - and /"

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo" || die "cannot enter $repo"

for tool in swift rsync ssh python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done

tailscale_bin=""
if command -v tailscale >/dev/null 2>&1; then
    tailscale_bin=$(command -v tailscale)
elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    tailscale_bin=/Applications/Tailscale.app/Contents/MacOS/Tailscale
else
    die "Tailscale was not found on PATH or in /Applications"
fi

# Nothing below prints an address: every line shown passes through this.
sanitize() { sed -E 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/<addr>/g'; }
say() { printf '%s\n' "$*" | sanitize; }

addr=$("$tailscale_bin" ip -4 2>/dev/null | head -n 1)
[[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Tailscale gave no IPv4 address; is it connected?"

if [ -z "$out" ]; then
    out=$(mktemp -d "${TMPDIR:-/tmp}/sensorium-bench.XXXXXX") || die "cannot create an output directory"
else
    mkdir -p "$out" || die "cannot create $out"
fi
state_dir="$out/state"
mkdir -p "$state_dir"
ssh_errors="$out/ssh.err"
say "raw files: $out"

standin_pid=""

stop_standin() {
    if [ -n "$standin_pid" ]; then
        kill -TERM "$standin_pid" 2>/dev/null
        wait "$standin_pid" 2>/dev/null
        standin_pid=""
    fi
}

trap stop_standin EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Quiet SSH: stdout is the caller's, stderr is kept in a file because it can
# name addresses.
vssh() { ssh -o BatchMode=yes -- "$viewer" "$@" 2>>"$ssh_errors"; }

fail() {
    say "benchmark-session: $* (SSH errors, if any, are in $ssh_errors)"
    exit 1
}

say "building the stand-in host"
swift build -c release --scratch-path .build/bench --product SensoriumBenchHost >"$out/build-bench-host.log" 2>&1 \
    || fail "building SensoriumBenchHost failed; see $out/build-bench-host.log"
bench_bin=$(swift build -c release --scratch-path .build/bench --product SensoriumBenchHost --show-bin-path 2>/dev/null)/SensoriumBenchHost
[ -x "$bench_bin" ] || fail "the stand-in host binary was not found"

say "syncing the tree to the viewer"
# The probe's scratch config starts empty: each invocation's stand-in has a new
# identity, and a pin saved for an earlier one at the same address would be
# chosen over the fresh pairing.
vssh "rm -rf '$remote_dir/xdg' && mkdir -p '$remote_dir/tree' '$remote_dir/runs' '$remote_dir/xdg'" \
    || fail "cannot reach the viewer over SSH"
remote_abs=$(vssh "cd '$remote_dir' && pwd") || fail "cannot resolve the remote directory"
[[ $remote_abs =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "the remote directory resolved to an unexpected path"
rsync -a --delete --exclude .build --exclude .git --exclude Artifacts -e "ssh -o BatchMode=yes" \
    "$repo/" "$viewer:$remote_abs/tree/" >"$out/rsync.log" 2>>"$ssh_errors" \
    || fail "rsync to the viewer failed"

probe_path=".build/release/SensoriumViewerProbe"
if [ -n "$probe_binary" ]; then
    probe_path=$probe_binary
    say "using the viewer probe at $probe_path on the viewer"
    vssh "cd '$remote_abs/tree' && test -x '$probe_path'" || fail "no executable probe at $probe_path on the viewer"
else
    say "building the viewer probe on the viewer"
    vssh "bash -lc 'cd \"$remote_abs/tree\" && swift build -c release --product SensoriumViewerProbe'" >"$out/build-viewer-probe.log" 2>&1 \
        || fail "building SensoriumViewerProbe on the viewer failed; see $out/build-viewer-probe.log"
fi

# Starts the stand-in in the background and waits for it to listen.
# $1 names its files; $2 is its time limit in seconds; a $3 of "run" gives it
# the --canvas and packet log, which the pairing does not need.
start_standin() {
    standin_log="$out/$1.host.log"
    standin_trace="$out/$1.trace"
    local canvas_args=()
    if [ "${3-}" = "run" ] && [ -n "$canvas" ]; then
        canvas_args=(--canvas "$canvas" --packet-log "$out/$1.packets")
    fi
    "$bench_bin" "$addr" "$port" --state-dir "$state_dir" --trace "$standin_trace" --max-seconds "$2" \
        ${canvas_args[@]+"${canvas_args[@]}"} >"$standin_log" 2>&1 &
    standin_pid=$!
    local waited=0
    while ! grep -q '^bench-host listening' "$standin_log" 2>/dev/null; do
        kill -0 "$standin_pid" 2>/dev/null || fail "the stand-in host exited before it listened; see $standin_log"
        [ "$waited" -lt 60 ] || fail "the stand-in host did not listen within 60 seconds; see $standin_log"
        sleep 1
        waited=$((waited + 1))
    done
}

say "pairing the viewer with the stand-in (once)"
start_standin pairing 180
code=$(sed -n 's/^bench-host pairing-code //p' "$standin_log" | head -n 1)
[ -n "$code" ] || fail "the stand-in host printed no pairing code"
# The code goes in on standard input so it never appears in a process list.
printf '%s\n' "$code" | vssh "bash -lc 'cd \"$remote_abs/tree\" && XDG_CONFIG_HOME=\"$remote_abs/xdg\" .build/release/SensoriumViewerProbe pair $addr $port'" \
    >"$out/pair.log" 2>&1 || fail "pairing failed; see $out/pair.log"
stop_standin

# One session. $1 is the label; $2 is "on" or "off" for release on interaction.
run_one() {
    local label=$1 release=$2
    local run_dir="$remote_abs/runs/$label"
    local flag=""
    [ "$release" = "off" ] && flag=" --no-interaction-release"
    say "run $label: interaction release $release"

    start_standin "$label" $((seconds + 120)) run

    local inner="Scripts/linux-headless-session.sh --width $width --height $height --scale $scale"
    inner="$inner --seconds $((seconds + 10)) --wait 10 --shot $run_dir/$label.png --log $run_dir/$label.log"
    inner="$inner -- $probe_path view $addr $port $seconds --pointer-plan $plan$flag"

    # Detached with setsid: an SSH hangup would otherwise kill the session. The
    # runtime directory is set because Tailscale SSH sessions lack it, and KWin
    # refuses to start without one.
    vssh "bash -s" <<REMOTE || fail "could not start the viewer session"
set -eu
mkdir -p "$run_dir"
rm -f "$run_dir/exit-code"
cd "$remote_abs/tree"
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export XDG_CONFIG_HOME="$remote_abs/xdg"
setsid nohup sh -c '$inner; echo \$? > "$run_dir/exit-code"' < /dev/null > /dev/null 2>&1 &
REMOTE

    local deadline=$(( $(date +%s) + seconds + 180 )) finished=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if vssh "test -f '$run_dir/exit-code'"; then finished=1; break; fi
        sleep 5
    done

    local viewer_status="timed out"
    if [ "$finished" -eq 1 ]; then
        viewer_status=$(vssh "cat '$run_dir/exit-code'")
    fi
    vssh "cat '$run_dir/$label.log'" >"$out/$label.viewer.log" 2>/dev/null
    vssh "cat '$run_dir/$label.png'" >"$out/$label.png" 2>/dev/null
    sed -n 's/^.*bench-viewer \({.*}\)$/\1/p' "$out/$label.viewer.log" | tail -n 1 >"$out/$label.bench-viewer.json"

    # The stand-in ends with the session; give it a bounded moment, then stop it.
    local waited=0
    while kill -0 "$standin_pid" 2>/dev/null && [ "$waited" -lt 60 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    stop_standin

    summarize "$label" "$release" "$viewer_status"
    [ "$viewer_status" = "0" ] || failures=$((failures + 1))
    if [ -n "$canvas" ]; then
        python3 -I "$repo/Scripts/summarize-motion-switches.py" "$out/$label.packets" "$out/$label.bench-viewer.json" \
            >"$out/$label.switches.txt" 2>&1 || failures=$((failures + 1))
        sanitize <"$out/$label.switches.txt"
    fi
}

# One line per run, read from the viewer's bench-viewer JSON, the stand-in's
# stdout and its trace file.
summarize() {
    python3 -I - "$out" "$1" "$2" "$3" <<'PY' | sanitize
import json, re, sys

out, label, release, status = sys.argv[1:5]

def load(path):
    try:
        with open(path) as handle:
            return handle.read()
    except OSError:
        return ""

def ms(nanoseconds):
    return "n/a" if nanoseconds is None else "%.1f" % (nanoseconds / 1e6)

def number(value):
    return "n/a" if value is None else "%.1f" % value

def stage(traces, name, key):
    entry = traces.get(name) or {}
    return entry.get(key)

text = load("%s/%s.bench-viewer.json" % (out, label)).strip()
try:
    viewer = json.loads(text)
except ValueError:
    print("%s release=%s viewer exit=%s: no bench-viewer line (see %s.viewer.log)" % (label, release, status, label))
    sys.exit(0)

traces = viewer.get("traces", {})
captured = re.findall(r"captured=(\d+)", load("%s/%s.host.log" % (out, label)))
encode = {}
for line in load("%s/%s.trace" % (out, label)).splitlines():
    try:
        record = json.loads(line)
    except ValueError:
        continue
    if record.get("stage") == "encode":
        encode = record

print(
    "%s release=%s viewer exit=%s | end-to-end p50/p95 %s/%s ms | receive p50 %s ms | present p50/p95 %s/%s ms"
    " | presented %s dropped %s | longest freeze during motion %s ms | first frame after motion resumes %s ms"
    " | host captured %s | host encode p50/p95 %s/%s ms" % (
        label, release, status,
        ms(stage(traces, "endToEnd", "p50Nanoseconds")), ms(stage(traces, "endToEnd", "p95Nanoseconds")),
        ms(stage(traces, "receive", "p50Nanoseconds")),
        ms(stage(traces, "present", "p50Nanoseconds")), ms(stage(traces, "present", "p95Nanoseconds")),
        viewer.get("presentedFrames", "n/a"), viewer.get("droppedFrames", "n/a"),
        number(viewer.get("longestPresentGapDuringMoveMs")),
        number(viewer.get("firstFrameAfterMoveStartMs")),
        captured[-1] if captured else "n/a",
        ms(encode.get("p50Nanoseconds")), ms(encode.get("p95Nanoseconds")),
    )
)
PY
}

failures=0
run=1
while [ "$run" -le "$runs" ]; do
    if [ "$ab" -eq 1 ]; then
        run_one "run$run-release-on" on
        run_one "run$run-release-off" off
    else
        run_one "run$run" on
    fi
    run=$((run + 1))
done

say "raw files: $out"
[ "$failures" -eq 0 ] || { say "$failures run(s) did not finish cleanly"; exit 1; }
