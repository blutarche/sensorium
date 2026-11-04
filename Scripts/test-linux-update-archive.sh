#!/bin/sh
# Checks the archive the Linux viewer updates itself from.
#
#   Scripts/test-linux-update-archive.sh [--run] [archive]
#
# Without an archive it checks Artifacts/Sensorium-<version>-linux-x86_64.tar.gz.
# The archive must hold exactly one regular file, Sensorium, mode 0755, owned
# by no one in particular, because the updater unpacks nothing else and trusts
# no path, owner or mode from inside it. With --run it also unpacks the
# binary and asks it for its usage, which needs a Linux machine with the
# viewer's libraries installed. The signing script reuses this check before it
# signs anything.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

RUN=0
ARCHIVE=""
for arg in "$@"; do
    case "$arg" in
        --run) RUN=1 ;;
        -*) echo "usage: $0 [--run] [archive]" >&2; exit 2 ;;
        *) ARCHIVE="$arg" ;;
    esac
done
[ -n "$ARCHIVE" ] || ARCHIVE="$ROOT/Artifacts/Sensorium-$VERSION-linux-x86_64.tar.gz"
[ -f "$ARCHIVE" ] || fail "no archive at $ARCHIVE"

# The archive is untrusted input: read it without extracting, and run Python
# in isolated mode so nothing beside the script can be imported.
python3 -I - "$ARCHIVE" <<'PY' || exit 1
import sys
import tarfile

path = sys.argv[1]


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
if member.name != "Sensorium":
    fail(f"the only entry must be named Sensorium, not {member.name!r}")
if not member.isreg():
    fail("Sensorium must be a regular file, not a directory, link or device")
if member.mode != 0o755:
    fail(f"Sensorium must be mode 0755, not {member.mode:04o}")
if member.uid != 0 or member.gid != 0 or member.uname or member.gname:
    fail("Sensorium must carry no owner: uid 0, gid 0, and no names")
if member.size == 0:
    fail("Sensorium is empty")
PY

if [ "$RUN" = 1 ]; then
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sensorium-update-archive.XXXXXX")"
    trap 'rm -rf "$SCRATCH"' EXIT
    # Safe to unpack: the check above proved the one entry is a plain Sensorium.
    tar -xzf "$ARCHIVE" -C "$SCRATCH" Sensorium
    usage="$("$SCRATCH/Sensorium" --help)" || fail "the archived Sensorium --help did not exit 0"
    echo "$usage" | grep -q "^usage: Sensorium " || fail "the archived Sensorium --help printed no usage"
fi

echo "PASS: $(basename "$ARCHIVE") holds one executable Sensorium and nothing else"
