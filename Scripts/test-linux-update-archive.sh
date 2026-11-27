#!/bin/sh
# Checks the archive the Linux viewer, or with --host the Linux host, updates
# itself from.
#
#   Scripts/test-linux-update-archive.sh [--host] [--run] [archive]
#
# Without an archive it checks Artifacts/Sensorium-<version>-linux-x86_64.tar.gz,
# or Artifacts/Sensorium-Host-<version>-linux-x86_64.tar.gz for the host. The
# archive must hold exactly one regular file, Sensorium or sensorium-host, mode
# 0755, owned by no one in particular, because the updater unpacks nothing else
# and trusts no path, owner or mode from inside it. With --run it also unpacks
# the binary and runs it, which needs a Linux machine with the app's libraries
# installed: the viewer is asked for its usage, and the host runs the self-test
# its updater runs, against an empty data folder, and must name this version.
# The signing script reuses this check before it signs anything.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

RUN=0
HOST=0
ARCHIVE=""
for arg in "$@"; do
    case "$arg" in
        --run) RUN=1 ;;
        --host) HOST=1 ;;
        -*) echo "usage: $0 [--host] [--run] [archive]" >&2; exit 2 ;;
        *) ARCHIVE="$arg" ;;
    esac
done
if [ "$HOST" = 1 ]; then
    MEMBER=sensorium-host
    PREFIX=Sensorium-Host-
else
    MEMBER=Sensorium
    PREFIX=Sensorium-
fi
[ -n "$ARCHIVE" ] || ARCHIVE="$ROOT/Artifacts/$PREFIX$VERSION-linux-x86_64.tar.gz"
[ -f "$ARCHIVE" ] || fail "no archive at $ARCHIVE"

# The archive is untrusted input: read it without extracting, and run Python
# in isolated mode so nothing beside the script can be imported.
python3 -I - "$ARCHIVE" "$MEMBER" <<'PY' || exit 1
import sys
import tarfile

path = sys.argv[1]
name = sys.argv[2]


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


try:
    archive = tarfile.open(path, "r:gz")
    members = archive.getmembers()
except (tarfile.TarError, OSError, EOFError) as error:
    fail(f"{path} is not a readable gzip tar archive ({error})")

if len(members) != 1:
    fail(f"the archive must hold exactly one entry, found {len(members)}")
member = members[0]
if member.name != name:
    fail(f"the only entry must be named {name}, not {member.name!r}")
if not member.isreg():
    fail(f"{name} must be a regular file, not a directory, link or device")
if member.mode != 0o755:
    fail(f"{name} must be mode 0755, not {member.mode:04o}")
if member.uid != 0 or member.gid != 0 or member.uname or member.gname:
    fail(f"{name} must carry no owner: uid 0, gid 0, and no names")
if member.size == 0:
    fail(f"{name} is empty")
PY

if [ "$RUN" = 1 ]; then
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sensorium-update-archive.XXXXXX")"
    trap 'rm -rf "$SCRATCH"' EXIT
    # Safe to unpack: the check above proved the one entry is a plain file.
    tar -xzf "$ARCHIVE" -C "$SCRATCH" "$MEMBER"
    if [ "$HOST" = 1 ]; then
        mkdir "$SCRATCH/data"
        output="$(XDG_DATA_HOME="$SCRATCH/data" "$SCRATCH/sensorium-host" --update-self-test)" ||
            fail "the archived sensorium-host --update-self-test did not exit 0"
        line="$(printf '%s\n' "$output" | head -n 1)"
        [ "$line" = "Sensorium Host $VERSION" ] ||
            fail "the archived sensorium-host names itself '$line', not Sensorium Host $VERSION"
        [ -z "$(ls -A "$SCRATCH/data")" ] || fail "the archived sensorium-host self-test wrote into its data folder"
    else
        usage="$("$SCRATCH/Sensorium" --help)" || fail "the archived Sensorium --help did not exit 0"
        echo "$usage" | grep -q "^usage: Sensorium " || fail "the archived Sensorium --help printed no usage"
    fi
fi

echo "PASS: $(basename "$ARCHIVE") holds one executable $MEMBER and nothing else"
