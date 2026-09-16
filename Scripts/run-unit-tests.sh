#!/bin/sh
# Runs every verification runner. Exits non-zero on the first failed assertion.
#
# XCTest and swift-testing are unavailable under Command Line Tools, so the
# runners are plain executables (see docs/testing.md).
set -eu

cd "$(dirname "$0")/.."

python3 Scripts/audit-public-repo.py
python3 Scripts/test-audit-public-repo.py
python3 Scripts/test-classify-host-permission-blocker.py
python3 Scripts/test-classify-workspace-focus-blocker.py
python3 Scripts/test-compare-display-inventory.py
python3 Scripts/test-check-display-active.py
python3 Scripts/test-documentation-status.py
# Both configurations. Release is what every packaging script ships, and it
# is the only place the optimizer's freedom -- ARC releasing an object at its
# last use, among others -- can change behaviour.
for configuration in debug release; do
    swift build -c "$configuration"

    for runner in Core Host Client Integration; do
        printf '== [%s] Sensorium%sTestRunner\n' "$configuration" "$runner"
        if [ "$runner" = "Host" ]; then
            # A real NSApplication window can leave this runner's own async
            # main() unable to finish, after which no Task.sleep resumes and
            # the rest of Entry.swift never runs -- with exit code 0 and no
            # FAIL line. Only its own "host runner: N of N" line catches that.
            output_file=$(mktemp)
            trap 'rm -f "$output_file"' EXIT INT TERM
            if ! swift run -c "$configuration" "Sensorium${runner}TestRunner" > "$output_file" 2>&1; then
                cat "$output_file"
                exit 1
            fi
            cat "$output_file"
            if ! awk '/^host runner: [0-9]+ of [0-9]+ test groups ran$/ { if ($3 == $5) found=1 } END { exit found ? 0 : 1 }' "$output_file"; then
                printf 'FAIL: Sensorium%sTestRunner ended without printing a matching "host runner: N of N test groups ran" line -- some registered test group never ran\n' "$runner" >&2
                exit 1
            fi
            rm -f "$output_file"
            trap - EXIT INT TERM
        else
            swift run -c "$configuration" "Sensorium${runner}TestRunner"
        fi
    done
done

Scripts/test-render-ui-previews.sh
Scripts/test-clipboard-sharing-gui-reachable.sh
Scripts/test-real-local-video-smoke.sh
Scripts/test-real-local-workspace-input-smoke.sh
Scripts/test-real-local-resize-smoke.sh
Scripts/test-real-local-focus-release-smoke.sh
Scripts/test-real-local-host-screen-smoke.sh

printf '\nAll runners passed.\n'
