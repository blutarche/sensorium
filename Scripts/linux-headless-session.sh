#!/usr/bin/env bash
# Runs one Linux viewer command inside a nested, virtual Wayland compositor and
# takes a screenshot of what it put on screen.
#
# The Linux viewer draws through Wayland and EGL, so the only honest check of
# "is the picture really there" is a screenshot of a real compositor. This
# script provides one without touching the desktop the person running it is
# using: KWin is started with `--virtual`, on a private session bus, with a
# Wayland socket of its own. Nothing the command inside opens can appear on, or
# take input from, the surrounding desktop.
#
# Usage:
#   Scripts/linux-headless-session.sh [options] -- <command> [arguments...]
#
#   --width N       virtual output width in pixels (default 1280)
#   --height N      virtual output height in pixels (default 800)
#   --scale F       virtual output scale (default 1.0)
#   --seconds N     how long the command is left running before the
#                   screenshot is taken (default 8)
#   --shot PATH     where the screenshot is written (default
#                   $TMPDIR/harness-shot.png, or /tmp if $TMPDIR is unset)
#   --log PATH      where the command's own output is written
#                   (default ./harness-command.log)
#   --wait N        how long the command is given to end by itself after the
#                   screenshot before it is asked to stop (default 0)
#
# The command is sent SIGTERM after the screenshot and given time to end on
# its own, so a session it opened is closed the way closing the window would
# close it. If it is still alive 5 seconds later it is sent SIGKILL, so
# --exit-with-session always returns.
set -u

self=$(readlink -f "$0")

if [ "${1-}" = "--inner" ]; then
    # Running as KWin's session: this is inside the nested compositor. This is
    # detected from an argv sentinel this script appends only when it
    # re-invokes itself through kwin_wayland's --exit-with-session, so a
    # polluted environment can never make the outer invocation take this
    # branch and run the harnessed command against a live session.
    if [ -z "${WAYLAND_DISPLAY-}" ] || [ "$WAYLAND_DISPLAY" = "wayland-0" ]; then
        echo "harness: refusing to run: WAYLAND_DISPLAY is '${WAYLAND_DISPLAY-}', which is not a nested socket" >&2
        exit 1
    fi
    if [ "$WAYLAND_DISPLAY" = "${SENSORIUM_HARNESS_OUTER_WAYLAND_DISPLAY-}" ]; then
        echo "harness: refusing to run: WAYLAND_DISPLAY '$WAYLAND_DISPLAY' was not set by the nested compositor" >&2
        exit 1
    fi
    echo "harness: nested compositor on $WAYLAND_DISPLAY"

    sh -c "$SENSORIUM_HARNESS_COMMAND" >"$SENSORIUM_HARNESS_LOG" 2>&1 &
    command_pid=$!

    command_exit_status=""
    elapsed=0
    while [ "$elapsed" -lt "$SENSORIUM_HARNESS_SECONDS" ]; do
        if ! kill -0 "$command_pid" 2>/dev/null; then
            wait "$command_pid"
            command_exit_status=$?
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    exit_status=0
    if [ -n "$command_exit_status" ] && [ "$command_exit_status" -ne 0 ]; then
        echo "harness: command exited with status $command_exit_status before the deadline" >&2
        exit_status=1
    fi

    if spectacle -b -n -f -o "$SENSORIUM_HARNESS_SHOT" >/dev/null 2>&1; then
        echo "harness: screenshot at $SENSORIUM_HARNESS_SHOT"
    else
        echo "harness: spectacle could not take a screenshot" >&2
        exit_status=1
    fi

    waited=0
    while [ "$waited" -lt "$SENSORIUM_HARNESS_WAIT" ]; do
        kill -0 "$command_pid" 2>/dev/null || break
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$command_pid" 2>/dev/null; then
        kill -TERM "$command_pid" 2>/dev/null
        for _ in $(seq 1 10); do
            kill -0 "$command_pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$command_pid" 2>/dev/null; then
            kill -KILL "$command_pid" 2>/dev/null
        fi
    fi
    wait "$command_pid" 2>/dev/null
    echo "harness: the command ended"
    echo "harness: exit status $exit_status" >>"$SENSORIUM_HARNESS_LOG"
    exit "$exit_status"
fi

width=1280
height=800
scale=1.0
seconds=8
wait_after_shot=0
shot="${TMPDIR:-/tmp}/harness-shot.png"
log="$PWD/harness-command.log"

while [ $# -gt 0 ]; do
    case "$1" in
        --width) width=$2; shift 2 ;;
        --height) height=$2; shift 2 ;;
        --scale) scale=$2; shift 2 ;;
        --seconds) seconds=$2; shift 2 ;;
        --wait) wait_after_shot=$2; shift 2 ;;
        --shot) shot=$2; shift 2 ;;
        --log) log=$2; shift 2 ;;
        --) shift; break ;;
        *) echo "harness: unknown option $1" >&2; exit 2 ;;
    esac
done

if [ $# -eq 0 ]; then
    echo "usage: $0 [options] -- <command> [arguments...]" >&2
    exit 2
fi

quoted=""
for argument in "$@"; do
    quoted="$quoted $(printf '%q' "$argument")"
done

export SENSORIUM_HARNESS_COMMAND="$quoted"
export SENSORIUM_HARNESS_SHOT="$shot"
export SENSORIUM_HARNESS_LOG="$log"
export SENSORIUM_HARNESS_SECONDS="$seconds"
export SENSORIUM_HARNESS_WAIT="$wait_after_shot"
export SENSORIUM_HARNESS_OUTER_WAYLAND_DISPLAY="${WAYLAND_DISPLAY-}"
inner_command="$(printf '%q' "$self") --inner"
# A nested compositor of its own, never the one the person is looking at.
exec env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
    dbus-run-session -- \
    kwin_wayland --virtual --width "$width" --height "$height" --scale "$scale" \
    --no-lockscreen --exit-with-session "$inner_command"
