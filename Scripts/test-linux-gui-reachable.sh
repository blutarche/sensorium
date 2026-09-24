#!/bin/sh
# Every viewer capability docs/ux-spec.md names has to be reachable from the
# Linux window layer, because the CLI verbs are test scaffolding and a
# capability nobody can reach from a window is not delivered.
#
# This greps the Linux window layer for each capability: the model symbol where
# the words belong to a portable model, and the literal where the words
# legitimately live in the view. It is a reachability check, not a rendering
# one -- what a person actually sees is the GUI check a human runs.
#
# usage: test-linux-gui-reachable.sh [--allow-missing <file>]
#   <file> lists one capability label per line that is known to be missing and
#   is not yet a failure. Comments start with #.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ALLOW_MISSING=""

while [ $# -gt 0 ]; do
  case "$1" in
    --allow-missing)
      [ $# -ge 2 ] || { printf 'usage: %s [--allow-missing <file>]\n' "$0" >&2; exit 2; }
      ALLOW_MISSING="$2"
      shift 2
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

SEARCH_DIR="$ROOT/Sources/SensoriumClient/Gtk"
[ -d "$SEARCH_DIR" ] || { printf 'no Linux window layer at %s\n' "$SEARCH_DIR" >&2; exit 1; }

# One capability per line: label|pattern. The pattern is a fixed string.
# Where the words come from a portable model, the model's own symbol is what
# must appear -- a literal copy of them in the window would be the duplication
# every model in this viewer exists to prevent. Where the words belong to the
# view, the literal is what must appear. Swift spells the ellipsis \u{2026},
# so no pattern carries one. No pattern carries a parenthesis either: this
# list is a heredoc inside a command substitution, and an unbalanced one ends
# the substitution early.
#
# The status panel's own buttons are named by `ViewerSessionStateMachine` and
# never written out in the window, so what is checked is the chain that
# carries them: the status arriving, the panel drawing every button it holds,
# a press finding one, and the action going back out.
CAPABILITIES=$(cat <<'EOF'
Your Machines heading|YourMachinesWindowModel.heading
Add a machine button|YourMachinesWindowModel.addTitle
Empty-list sentence|YourMachinesWindowModel.emptySentence
Row detail line|row.detail
Row reachability dot|row.dot
Per-row Cancel|row.offersCancel
Pair again|Pair again
Forget|Forget
Connect with a virtual display|Connect with a virtual display
Look again|Look again
Enter address manually|Enter address manually
Code step headline|Type the Code Shown on
Status panel words|status: ViewerSessionStatus
Status panel buttons drawn|SessionChromePainter.drawStatusPanel
Status panel button pressed|ViewerStatusPanelHitTest.action
Status panel action reported|chrome.onSessionAction
EOF
)

is_allowed_missing() {
  [ -n "$ALLOW_MISSING" ] || return 1
  [ -f "$ALLOW_MISSING" ] || return 1
  while IFS= read -r allowed; do
    case "$allowed" in
      ''|\#*) continue ;;
    esac
    [ "$allowed" = "$1" ] && return 0
  done < "$ALLOW_MISSING"
  return 1
}

missing=""
allowed_missing=""
found_unexpectedly=""

OLDIFS=$IFS
IFS='
'
for entry in $CAPABILITIES; do
  label=${entry%%|*}
  pattern=${entry#*|}
  if grep -rqF -- "$pattern" "$SEARCH_DIR" "$ROOT"/Sources/SensoriumClient/WaylandSessionWindow*.swift; then
    if is_allowed_missing "$label"; then
      found_unexpectedly="$found_unexpectedly
  $label"
    fi
  else
    if is_allowed_missing "$label"; then
      allowed_missing="$allowed_missing
  $label"
    else
      missing="$missing
  $label"
    fi
  fi
done
IFS=$OLDIFS

if [ -n "$missing" ]; then
  printf 'The Linux window layer does not reach these viewer capabilities:%s\n' "$missing" >&2
  exit 1
fi

if [ -n "$found_unexpectedly" ]; then
  printf 'These capabilities are reachable now and must be removed from %s:%s\n' "$ALLOW_MISSING" "$found_unexpectedly" >&2
  exit 1
fi

if [ -n "$allowed_missing" ]; then
  printf 'PASS: every viewer capability is reachable from the Linux window layer, except these, still listed as pending:%s\n' "$allowed_missing"
else
  printf 'PASS: every viewer capability docs/ux-spec.md names is reachable from the Linux window layer\n'
fi
