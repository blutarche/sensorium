#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/Artifacts"
test_root=$(mktemp -d "$root/Artifacts/headless-session-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
mkdir "$test_root/bin" "$test_root/config"
printf 'original\n' > "$test_root/config/kwinoutputconfig.json"
export SENSORIUM_TEST_OUTER_CONFIG="$test_root/config"
export SENSORIUM_TEST_RESULT="$test_root/config-used"
export TMPDIR="$test_root"

cat > "$test_root/bin/dbus-run-session" <<'SH'
#!/bin/sh
shift
exec "$@"
SH
cat > "$test_root/bin/kwin_wayland" <<'SH'
#!/bin/sh
set -eu
if [ "$XDG_CONFIG_HOME" = "$SENSORIUM_TEST_OUTER_CONFIG" ]; then
    echo "FAIL: nested compositor inherited the active desktop's configuration" >&2
    exit 1
fi
printf '%s\n' "$XDG_CONFIG_HOME" > "$SENSORIUM_TEST_RESULT"
printf 'virtual output\n' > "$XDG_CONFIG_HOME/kwinoutputconfig.json"
SH
chmod +x "$test_root/bin/"*
PATH="$test_root/bin:$PATH" XDG_CONFIG_HOME="$test_root/config" \
    bash "$root/Scripts/linux-headless-session.sh" --scale 1.5 -- true

[ "$(cat "$test_root/config/kwinoutputconfig.json")" = original ]
[ ! -e "$(cat "$SENSORIUM_TEST_RESULT")" ]
echo "PASS: nested compositor config is isolated and removed"
