#!/bin/sh
# Prints the command that reports whether the tailnet path is direct or
# DERP-relayed. Run it by hand before making a latency claim.
set -eu

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    echo "usage: $0 <host-name-or-address>" >&2
    exit 2
fi

echo "Run:"
echo "  tailscale ping --verbose ${TARGET}"
echo
echo "'direct' is the low-latency path; 'via DERP' is relayed. Name which"
echo "path a benchmark came from."
