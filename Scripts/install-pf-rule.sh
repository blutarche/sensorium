#!/bin/sh
# Prints the PF anchor that restricts the Sensorium UDP port to Tailscale
# ranges, and the commands to install it. It changes nothing itself.
#
# Not run by any automation here: applying its output needs sudo, so a
# person reads it and runs it deliberately.
#
#   usage: install-pf-rule.sh <port>
#          install-pf-rule.sh --uninstall
#
# It touches only its own anchor file and never rewrites /etc/pf.conf rules that
# belong to anything else, including Screen Sharing.
set -eu

ANCHOR_NAME="com.sensorium"
ANCHOR_FILE="/etc/pf.anchors/${ANCHOR_NAME}"

if [ "${1:-}" = "--uninstall" ]; then
    echo "Remove ${ANCHOR_FILE} and the matching anchor lines from /etc/pf.conf, then run:"
    echo "  sudo pfctl -f /etc/pf.conf"
    exit 0
fi

PORT="${1:-}"
if [ -z "$PORT" ]; then
    echo "usage: $0 <port> | --uninstall" >&2
    exit 2
fi

cat <<RULES
Write this to ${ANCHOR_FILE}:

  block in quick proto udp to port ${PORT}
  pass in quick proto udp from 100.64.0.0/10 to port ${PORT}
  pass in quick inet6 proto udp from fd7a:115c:a1e0::/48 to port ${PORT}

Then add to /etc/pf.conf:

  anchor "${ANCHOR_NAME}"
  load anchor "${ANCHOR_NAME}" from "${ANCHOR_FILE}"

Reload with:

  sudo pfctl -f /etc/pf.conf

Verify from a LAN address that the port is refused, and from a tailnet address
that it is reachable. The host also rejects non-tailnet sources on its own; the
anchor is the outer layer, not the only one.
RULES
